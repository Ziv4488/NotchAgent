//
//  SessionStore.swift
//  NotchAgent
//
//  活着的会话（spec 4.2）。tab 的展示数据在 IslandModel，这里只管进程那一侧。
//

import Foundation

/// 持有所有活着的 `CLISession`，并负责把 hook 事件绑回到对应的 tab。
@MainActor
final class SessionStore {
    private(set) var sessions: [SessionID: CLISession] = [:]
    /// Claude Code 的 session id → 我们的 tab id。
    private var claudeBindings: [String: SessionID] = [:]

    var runningCount: Int { sessions.values.filter { $0.status.isAlive }.count }

    func add(_ session: CLISession) {
        sessions[session.id] = session
    }

    func remove(_ id: SessionID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.terminate()
        claudeBindings = claudeBindings.filter { $0.value != id }
    }

    func session(_ id: SessionID) -> CLISession? { sessions[id] }

    var all: [CLISession] { Array(sessions.values) }

    func terminateAll() {
        for session in sessions.values { session.terminate() }
        sessions.removeAll()
        claudeBindings.removeAll()
    }

    // MARK: - 事件绑定

    /// 一条 hook 事件属于哪个 tab。
    ///
    /// 三条路，按可靠性排序：
    /// 1. 转发时带过来的 `NOTCH_TAB` —— 我们自己注入的环境变量，最确切
    /// 2. 已经建立的 `session_id` → tab 绑定
    /// 3. 按 `cwd` 兜底匹配一个还没绑定的会话
    ///
    /// 第 3 条存在的意义：用户可能在会话里 `/clear`，Claude Code 会换一个新的
    /// `session_id` 重开，此时环境变量还在（同一个进程），所以其实第 1 条就够了；
    /// 但万一将来转发方式变了，按目录兜底比整条通道哑掉强。
    func resolve(event: HookEvent, declaredTab: SessionID?) -> CLISession? {
        if let declaredTab, let session = sessions[declaredTab] {
            bind(session: session, to: event.sessionID)
            return session
        }
        if let bound = claudeBindings[event.sessionID], let session = sessions[bound] {
            return session
        }
        guard let cwd = event.cwd else { return nil }
        let match = sessions.values.first {
            $0.claudeSessionID == nil && $0.workingDirectory?.standardizedFileURL.path == cwd
        }
        if let match { bind(session: match, to: event.sessionID) }
        return match
    }

    private func bind(session: CLISession, to claudeSessionID: String) {
        guard session.claudeSessionID != claudeSessionID else { return }
        session.bind(claudeSessionID: claudeSessionID)
        claudeBindings[claudeSessionID] = session.id
    }
}
