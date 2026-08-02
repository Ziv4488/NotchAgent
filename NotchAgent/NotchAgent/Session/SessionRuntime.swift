//
//  SessionRuntime.swift
//  NotchAgent
//
//  把 ClaudeLocator / SessionStore / HookBridge / StatusFeed 串成一条链，
//  再把结果喂给 IslandModel（spec 4.3 的数据流）。
//

import AppKit
import Foundation
import OSLog

/// 会话层的总装。`IslandModel` 只跟它说话，不认识 PTY、socket、hook。
@MainActor
final class SessionRuntime {
    let store = SessionStore()
    let bridge: HookBridge
    let preferences: Preferences

    /// `claude` 在哪、以及登录 shell 的 PATH。启动时解析一次。
    private(set) var location: ClaudeLocator.Result = .notFound(searchPath: "")

    /// hook 通道**没起来**时的原因，起来了就是 nil（spec 6.4 那条降级）。
    ///
    /// 这件事以前只写进 `Logger` —— 也就是只有开着 Console.app 的人看得见。
    /// 用户那边的表现是：终端一切正常，但收起态永远只有项目名、没有
    /// 「读 session.ts」这种进度，完成也不会亮绿点。看起来像功能坏了，
    /// 其实是通道没连上。得让界面说出来。
    private(set) var hookChannelFailure: String?

    /// 事件已经翻译成「对某个 tab 的影响」，交给上层落到 UI 上。
    var onSignal: ((SessionID, SessionSignal) -> Void)?
    /// 会话进程状态变了（起来了 / 退出了 / 崩了）。
    var onStatusChanged: ((SessionID, SessionStatus) -> Void)?
    /// 终端里摆出了一道选择题，或者刚才那道没了（nil）。
    var onMenu: ((SessionID, TerminalMenu?) -> Void)?
    /// 用户按 Esc 把这一轮掐了。**hook 通道在这条路上一条事件都不发**
    /// （`scripts/spike-escape.py` 实测），只有这一个信号说得出「它不跑了」。
    var onTurnCancelled: ((SessionID) -> Void)?

    private let log = Logger(subsystem: "com.notchagent", category: "runtime")

    init(bridge: HookBridge? = nil, preferences: Preferences = Preferences()) {
        self.bridge = bridge ?? HookBridge()
        self.preferences = preferences
    }

    // MARK: - 启动

    func start() {
        location = ClaudeLocator(override: preferences.claudePath).locate()
        switch location {
        case .found(let path, _):
            log.info("claude: \(path, privacy: .public)")
        case .notFound(let searchPath):
            log.error("PATH 里找不到 claude：\(searchPath, privacy: .public)")
        }

        bridge.onEvent = { [weak self] event, declaredTab in
            self?.handle(event, declaredTab: declaredTab)
        }
        do {
            try bridge.start()
            hookChannelFailure = nil
        } catch {
            // hook 通道起不来不该拖垮整个 app：PTY 那条路是独立的（spec 4.3），
            // 终端照样能用，只是收起态没有进度文案。
            hookChannelFailure = error.localizedDescription
            log.error("hook 通道启动失败，降级成「运行中（无详情）」：\(error.localizedDescription, privacy: .public)")
        }

        startWatchingMenus()
    }

    /// 关整个 app。**退出确认框上写的那句话必须是真的。**
    ///
    /// `store.terminateAll()` 只管得着岛自己的子进程。Claude Code 2.1 会把会话
    /// 交给它自己的守护进程，交出去的那些得按命令行特征再扫一遍：岛起的 claude
    /// 都带着**岛自己那份** settings 文件的绝对路径，用户在终端里自己跑的不会带。
    /// 顺带也收掉以前那些残留下来的（见 `SessionReaper` 里记的那两个）。
    func shutdown() {
        menuTimer?.invalidate()
        menuTimer = nil
        store.terminateAll()
        reaper.reap(signature: Self.launchSignature(settingsURL: bridge.settingsURL))
        bridge.stop()
    }

    /// 岛起的 claude 在命令行里长什么样。抽出来是为了能单测。
    nonisolated static func launchSignature(settingsURL: URL) -> String {
        "--settings \(settingsURL.path)"
    }

    /// 收尾用。单测替换成假的，免得真去 pgrep。
    var reaper = SessionReaper()

    // MARK: - 起会话

    enum LaunchError: LocalizedError {
        case claudeNotFound(searchPath: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                "找不到 claude 命令。请在设置里手填它的绝对路径。"
            }
        }
    }

    @discardableResult
    func launch(id: SessionID = UUID(), title: String, directory: URL?,
                instruction: String?, resume: Bool = false) throws -> CLISession {
        guard case .found(let executable, let searchPath) = location else {
            if case .notFound(let searchPath) = location {
                throw LaunchError.claudeNotFound(searchPath: searchPath)
            }
            throw LaunchError.claudeNotFound(searchPath: "")
        }

        let session = CLISession(
            id: id,
            title: title,
            workingDirectory: directory,
            launch: .claude(executable: executable, searchPath: searchPath,
                            settingsURL: bridge.settingsURL,
                            instruction: instruction, resume: resume))
        session.callbacks.onStatusChanged = { [weak self] id, status in
            self?.onStatusChanged?(id, status)
        }
        session.callbacks.onEscape = { [weak self] id in
            guard let self else { return }
            // 选单跟着 Esc 一起没了。**自己先忘掉**，别等下一拍扫描回来报
            // 「选单没了」——那条路会把状态当成「答完了」重新交回 `.running`。
            pendingMenus[id] = nil
            reportedMenus[id] = nil
            onTurnCancelled?(id)
        }
        store.add(session)
        try session.start()
        return session
    }

    func session(_ id: SessionID) -> CLISession? { store.session(id) }

    func write(_ text: String, to id: SessionID) {
        store.session(id)?.write(text)
        quickenMenuScan()
    }

    /// 按一下 ↑（岛上那个「返回选项」）。
    func sendCursorUp(to id: SessionID) {
        store.session(id)?.sendCursorUp()
        quickenMenuScan()
    }

    /// 停止键：给 PTY 发 `Esc`，等价于在终端里按 Esc（见 `CLISession.interrupt`）。
    func interrupt(_ id: SessionID) {
        store.session(id)?.interrupt()
    }

    func close(_ id: SessionID) {
        store.remove(id)
    }

    var hasLiveSessions: Bool { store.runningCount > 0 }

    // MARK: - 盯着终端上的选择题

    /// 上一拍看到的（还没确认），和已经报上去的。
    private var pendingMenus: [SessionID: TerminalMenu?] = [:]
    private var reportedMenus: [SessionID: TerminalMenu?] = [:]
    private var menuTimer: Timer?

    /// 轮询而不是等回调：SwiftTerm 的 delegate 里**没有「收到数据」这一项**
    /// （只有 sizeChanged / setTerminalTitle / processTerminated），
    /// 而选单是纯屏幕现象，没有任何事件对应它。
    ///
    /// 半秒扫一次四十行缓冲区，代价可以忽略。
    private func startWatchingMenus(every interval: TimeInterval = menuPollInterval) {
        menuTimer?.invalidate()
        menuTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForMenus() }
        }
    }

    static let menuPollInterval: TimeInterval = 0.5
    /// 刚打过字之后的那两秒，扫得密一些。
    static let quickPollInterval: TimeInterval = 0.12
    private static let quickPollWindow: TimeInterval = 2

    /// 刚往 PTY 里写过东西 —— 屏幕马上就要变，接下来这两秒盯紧一点。
    ///
    /// 平时半秒一拍、还要**连着两拍一样**才上报（防止扫到画到一半的选单），
    /// 于是「点了 Type something. 到岛上真的换成输入框」最坏要等 1.5 秒 ——
    /// 用户报的「转换太慢」。而我们自己写字的那一刻是**确切知道**屏幕要变的，
    /// 那时候没有理由还按空闲节奏等。两秒后自己回到半秒一拍。
    private func quickenMenuScan() {
        quickScanDeadline = Date().addingTimeInterval(Self.quickPollWindow)
        startWatchingMenus(every: Self.quickPollInterval)
    }

    private var quickScanDeadline: Date?

    private func scanForMenus() {
        var alive = Set<SessionID>()
        for session in store.all where session.status.isAlive {
            alive.insert(session.id)
            let menu = TerminalMenu.parse(session.visibleLines())

            // **连着两拍一样才算数。** 选单是一行行画出来的，扫在半中间会得到
            // 一个选项不全的版本；隔半秒再看一眼，稳定了才往上报。
            let confirmed = pendingMenus[session.id].map { $0 == menu } ?? false
            pendingMenus[session.id] = menu
            guard confirmed else { continue }

            let reported = reportedMenus[session.id] ?? nil
            guard reported != menu else { continue }
            reportedMenus[session.id] = menu
            onMenu?(session.id, menu)
        }

        // 会话没了就把记录清掉，免得越攒越多。
        pendingMenus = pendingMenus.filter { alive.contains($0.key) }
        reportedMenus = reportedMenus.filter { alive.contains($0.key) }

        // 密集那一阵过去了，回到空闲节奏。
        if let deadline = quickScanDeadline, Date() >= deadline {
            quickScanDeadline = nil
            startWatchingMenus()
        }
    }

    // MARK: - hook 事件落地

    private func handle(_ event: HookEvent, declaredTab: SessionID?) {
        guard let session = store.resolve(event: event, declaredTab: declaredTab) else {
            log.debug("事件对不上任何 tab：\(event.kind.rawValue, privacy: .public)")
            return
        }
        onSignal?(session.id, StatusFeed.signal(for: event))
    }
}
