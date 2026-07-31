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

    /// 事件已经翻译成「对某个 tab 的影响」，交给上层落到 UI 上。
    var onSignal: ((SessionID, SessionSignal) -> Void)?
    /// 会话进程状态变了（起来了 / 退出了 / 崩了）。
    var onStatusChanged: ((SessionID, SessionStatus) -> Void)?
    /// 终端里摆出了一道选择题，或者刚才那道没了（nil）。
    var onMenu: ((SessionID, TerminalMenu?) -> Void)?

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
        } catch {
            // hook 通道起不来不该拖垮整个 app：PTY 那条路是独立的（spec 4.3），
            // 终端照样能用，只是收起态没有进度文案。
            log.error("hook 通道启动失败，降级成「运行中（无详情）」：\(error.localizedDescription, privacy: .public)")
        }

        startWatchingMenus()
    }

    func shutdown() {
        menuTimer?.invalidate()
        menuTimer = nil
        store.terminateAll()
        bridge.stop()
    }

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
        store.add(session)
        try session.start()
        return session
    }

    func session(_ id: SessionID) -> CLISession? { store.session(id) }

    func write(_ text: String, to id: SessionID) {
        store.session(id)?.write(text)
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
    private func startWatchingMenus() {
        menuTimer = Timer.scheduledTimer(withTimeInterval: Self.menuPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForMenus() }
        }
    }

    static let menuPollInterval: TimeInterval = 0.5

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
