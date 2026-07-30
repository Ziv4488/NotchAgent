//
//  HookBridge.swift
//  NotchAgent
//
//  Claude Code 的 hook 事件通道（spec 5.2）：
//  hook 命令 → Unix domain socket → 这里 → StatusFeed。
//

import Darwin
import Foundation
import OSLog
import os

/// 监听一个 Unix domain socket，把 Claude Code 的 hook 事件解出来分发。
///
/// **转发端用系统自带的 `nc`，不带自己的小程序。**
/// 计划里原本要在 bundle 里放一个 `hook-forward` 可执行文件，那需要在 Xcode 里
/// 多加一个 target、再配一条拷贝进 bundle 的构建阶段。`/usr/bin/nc` 是 macOS 自带的，
/// `-U` 走 Unix socket，stdin 读完就退出，实测一次往返 30ms、
/// socket 不存在时 25ms 内直接失败退出 —— 完全满足「绝不阻塞 Claude Code」这条硬要求。
///
/// **不能加 `-N`。** 手册上 `-N` 是「stdin EOF 后关闭写端」，听起来正合用，
/// 但这台 macOS 上的 nc 一见 `-N` 就报 `invalid tcp adaptive write timeout value`
/// 并以 1 退出，一个字节都发不出去。这个坑很难发现：命令退得飞快，
/// 只看耗时会以为它成功了 —— 所以下面那条端到端测试断言的是**收到了事件**，不是耗时。
///
/// **事件怎么绑到 tab**：`session_id` 是 Claude Code 自己的，它在 `SessionStart`
/// 之前我们无从得知。所以 spawn `claude` 时注入 `NOTCH_TAB=<我们的 tab id>`，
/// hook 命令继承得到（已实测），把它作为**第一行**发过来，JSON 跟在后面。
@MainActor
final class HookBridge {
    /// 解出来的事件 + 发出它的 tab（拿不到就是 nil，交给调用方按 cwd 兜底）。
    var onEvent: ((HookEvent, UUID?) -> Void)?

    private let socketURL: URL
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let log = Logger(subsystem: "com.notchagent", category: "hooks")

    init(socketURL: URL? = nil) {
        self.socketURL = socketURL ?? Self.defaultSocketURL
    }

    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "NotchAgent")
    }

    static var defaultSocketURL: URL {
        supportDirectory.appending(path: "hooks.sock")
    }

    /// 传给 `claude --settings` 的文件。**在运行时生成而不是放进 bundle** ——
    /// 里面要写死 socket 的绝对路径，那是安装后才知道的。
    var settingsURL: URL {
        socketURL.deletingLastPathComponent().appending(path: "island-hooks.json")
    }

    // MARK: - 启停

    enum BridgeError: LocalizedError {
        case socketFailed(String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .socketFailed(let step, let code):
                "hook socket \(step) 失败：\(String(cString: strerror(code)))"
            }
        }
    }

    /// **用裸 BSD socket，不用 Network.framework。**
    ///
    /// `NWListener` 配 `requiredLocalEndpoint: .unix(path:)` 在这台机器上直接被系统拒了
    /// （`nw_listener_socket_inbox_create_socket setsockopt SO_NECP_LISTENUUID failed [22]`），
    /// 监听建起来但一个连接都收不到。Network.framework 对 AF_UNIX 的支持本来就是半吊子，
    /// 而这里要的东西极其简单：一个本地 socket，一条连接一个事件。
    func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 上次没干净退出会留下 socket 文件，不清掉 bind 直接 EADDRINUSE。
        try? FileManager.default.removeItem(at: socketURL)
        try writeSettings()

        let path = socketURL.path
        // sockaddr_un.sun_path 是 104 字节的定长数组，超了会被静默截断，
        // 于是 bind 到一个不完整的路径上、hook 那边怎么连都连不上。
        guard path.utf8.count < 104 else {
            throw BridgeError.socketFailed("路径过长（\(path.utf8.count) 字节，上限 103）", errno: ENAMETOOLONG)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socketFailed("创建", errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strlcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                        source, 104)
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.socketFailed("bind", errno: code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.socketFailed("listen", errno: code)
        }

        listenFD = fd
        // **收包全程在自己的串行队列上，不用 .main。**
        // 主队列在某些宿主里（比如测试运行器）不一定被及时排空，
        // 而 hook 事件迟到就等于岛的状态迟到。解好的事件再跳回主线程去改模型。
        let queue = self.queue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.read(from: client)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        log.info("hook socket 已监听 \(path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: - 收包

    /// 一条连接 = 一个事件，读到 EOF 才解析。
    ///
    /// payload 有几 KB（`tool_response` 会把整个文件内容带上），一定会分片到达；
    /// 见到第一个包就解会解到半截 JSON。
    private nonisolated func read(from client: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let accumulated = Accumulator()
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(client, &chunk, chunk.count)
            if count > 0 {
                accumulated.data.append(contentsOf: chunk[0..<count])
                return
            }
            // 0 = 对端写完了；<0 = 出错。两种都到此为止。
            source.cancel()
            guard count == 0 else { return }
            let payload = accumulated.data
            Task { @MainActor [weak self] in self?.handle(payload) }
        }
        source.setCancelHandler { [weak self] in
            close(client)
            self?.forget(source)
        }
        source.resume()
        // 不留住就会被立刻释放，事件一个都收不到。
        live.withLock { $0.append(source) }
    }

    private nonisolated func forget(_ source: DispatchSourceRead) {
        live.withLock { $0.removeAll { $0 === source } }
    }

    /// 收包只发生在 `queue` 上，所以这里不需要再加锁。
    private final class Accumulator: @unchecked Sendable {
        var data = Data()
    }

    private nonisolated let queue = DispatchQueue(label: "com.notchagent.hooks")
    private nonisolated let live = OSAllocatedUnfairLock<[DispatchSourceRead]>(initialState: [])

    private func handle(_ data: Data) {
        let (tab, payload) = Self.split(data)
        guard let event = HookEvent.decode(payload) else {
            log.error("hook 事件解不开，丢弃 \(data.count) 字节")
            return
        }
        // 这条通道断了的表现是「岛一直不动」，很难和「任务真的没进展」区分开。
        // 留一条 info 日志，`log stream --predicate 'subsystem == "com.notchagent"'` 就能确诊。
        log.info("hook \(event.kind.rawValue, privacy: .public) tab=\(tab?.uuidString ?? "-", privacy: .public)")
        onEvent?(event, tab)
    }

    /// 拆出「第一行的 tab id」和「JSON 正文」。
    ///
    /// 第一行不像 UUID 就当它不存在，整包都是 JSON —— 这样即使将来
    /// 转发方式变了、或者用户手动往 socket 里灌一条 payload 调试，也照样能收。
    nonisolated static func split(_ data: Data) -> (tab: UUID?, payload: Data) {
        guard let newline = data.firstIndex(of: 0x0A) else { return (nil, data) }
        let head = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let uuid = UUID(uuidString: head) else { return (nil, data) }
        return (uuid, Data(data[data.index(after: newline)...]))
    }

    // MARK: - 生成 --settings

    /// 只写 hooks，不写别的键。
    ///
    /// 探针已验证 `--settings` 与用户的 `~/.claude/settings.json` 是**合并**语义、
    /// 且不同来源的 hooks **叠加**触发，所以这份文件不会顶掉用户自己的 hook 配置。
    /// 反过来也意味着：这里多写一个键就会覆盖用户的同名设置，所以这里**只能有 hooks**。
    func writeSettings() throws {
        let json = try JSONSerialization.data(
            withJSONObject: ["hooks": Self.hooks(socketPath: socketURL.path)],
            options: [.prettyPrinted, .sortedKeys])
        try json.write(to: settingsURL, options: .atomic)
    }

    nonisolated static func hooks(socketPath: String) -> [String: Any] {
        // 事件先写 tab id 再写 payload，然后整体喂给 nc。
        // 末尾的 `|| true` 是硬要求：hook 命令非零退出会被 Claude Code 当成错误报给用户，
        // 岛没开着的时候每一次工具调用都弹一次红字是不能接受的。
        let forward = "{ echo \"$NOTCH_TAB\"; cat; } | /usr/bin/nc -U -w 1 '\(socketPath)' >/dev/null 2>&1 || true"
        let entry: [String: Any] = ["hooks": [["type": "command", "command": forward]]]
        let matched: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": forward]]]
        return [
            "SessionStart": [entry],
            "PreToolUse": [matched],
            "PostToolUse": [matched],
            "Notification": [entry],
            "Stop": [entry],
        ]
    }
}
