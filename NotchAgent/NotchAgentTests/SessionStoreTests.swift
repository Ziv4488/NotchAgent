//
//  SessionStoreTests.swift
//  NotchAgentTests
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("会话仓库与事件绑定")
@MainActor
struct SessionStoreTests {

    private func makeSession(id: SessionID = UUID(), directory: String?) -> CLISession {
        CLISession(id: id, title: "测试",
                   workingDirectory: directory.map { URL(fileURLWithPath: $0) },
                   launch: CLISession.Launch(executable: "/bin/sh", arguments: ["-c", "true"],
                                             searchPath: "/usr/bin:/bin", settingsURL: nil))
    }

    private func event(_ kind: HookEvent.Kind, session: String, cwd: String?) -> HookEvent {
        HookEvent(kind: kind, sessionID: session, cwd: cwd)
    }

    @Test("转发带来的 tab id 最优先，直接命中")
    func resolvesByDeclaredTab() {
        let store = SessionStore()
        let session = makeSession(directory: "/tmp/a")
        store.add(session)
        let resolved = store.resolve(event: event(.sessionStart, session: "c1", cwd: "/tmp/a"),
                                     declaredTab: session.id)
        #expect(resolved === session)
        #expect(session.claudeSessionID == "c1")
    }

    /// 第一条事件把 Claude 的 session id 绑上去，往后即使没有身份行也认得出来。
    @Test("绑定一次之后，后续事件靠 session_id 就能对上")
    func remembersBinding() {
        let store = SessionStore()
        let session = makeSession(directory: "/tmp/a")
        store.add(session)
        _ = store.resolve(event: event(.sessionStart, session: "c1", cwd: "/tmp/a"),
                          declaredTab: session.id)
        let later = store.resolve(event: event(.stop, session: "c1", cwd: nil), declaredTab: nil)
        #expect(later === session)
    }

    @Test("没有身份行也没绑过时，按工作目录兜底")
    func fallsBackToWorkingDirectory() {
        let store = SessionStore()
        let a = makeSession(directory: "/tmp/a")
        let b = makeSession(directory: "/tmp/b")
        store.add(a)
        store.add(b)
        let resolved = store.resolve(event: event(.sessionStart, session: "c9", cwd: "/tmp/b"),
                                     declaredTab: nil)
        #expect(resolved === b)
    }

    /// 同一个目录开两个会话是常见的。按目录兜底只认还没绑定的那个，
    /// 否则第二个会话的事件会全部打到第一个 tab 上。
    @Test("同目录的两个会话：兜底只认还没绑过的那个")
    func doesNotStealBoundSessions() {
        let store = SessionStore()
        let first = makeSession(directory: "/tmp/same")
        let second = makeSession(directory: "/tmp/same")
        store.add(first)
        store.add(second)
        _ = store.resolve(event: event(.sessionStart, session: "c1", cwd: "/tmp/same"),
                          declaredTab: first.id)

        let resolved = store.resolve(event: event(.sessionStart, session: "c2", cwd: "/tmp/same"),
                                     declaredTab: nil)
        #expect(resolved === second)
    }

    @Test("对不上任何会话时返回 nil，不乱认一个")
    func returnsNilWhenNothingMatches() {
        let store = SessionStore()
        store.add(makeSession(directory: "/tmp/a"))
        #expect(store.resolve(event: event(.stop, session: "zzz", cwd: "/tmp/elsewhere"),
                              declaredTab: nil) == nil)
    }

    @Test("移除会话后它的绑定也一起清掉，不留下会认错的残留")
    func removeClearsBindings() {
        let store = SessionStore()
        let session = makeSession(directory: "/tmp/a")
        store.add(session)
        _ = store.resolve(event: event(.sessionStart, session: "c1", cwd: "/tmp/a"),
                          declaredTab: session.id)
        store.remove(session.id)
        #expect(store.session(session.id) == nil)
        #expect(store.resolve(event: event(.stop, session: "c1", cwd: nil), declaredTab: nil) == nil)
    }

    @Test("路径写法不同（末尾斜杠、//）也要认得出是同一个目录")
    func normalizesPaths() {
        let store = SessionStore()
        let session = makeSession(directory: "/tmp/a/")
        store.add(session)
        #expect(store.resolve(event: event(.sessionStart, session: "c1", cwd: "/tmp/a"),
                              declaredTab: nil) === session)
    }
}

@Suite("持久化")
struct PersistenceTests {

    @Test("tab 骨架存下来再读回去，一模一样")
    func roundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-tabs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshots = [
            TabSnapshot(id: UUID(), title: "refactor-auth", directory: "/tmp/a", claudeSessionID: "c1"),
            TabSnapshot(id: UUID(), title: "写测试", directory: nil, claudeSessionID: nil),
        ]
        TabStore.save(snapshots, to: url)
        #expect(TabStore.load(from: url) == snapshots)
    }

    /// 文件被手改坏、或者上一版的格式对不上，都不该让 app 起不来 ——
    /// 大不了 tab 条是空的，用户重新开一个就是了。
    @Test("文件损坏或不存在时返回空数组，不抛不崩")
    func survivesCorruption() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-broken-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(TabStore.load(from: url).isEmpty)
        try Data("这不是 JSON".utf8).write(to: url)
        #expect(TabStore.load(from: url).isEmpty)
    }

    @Test("展开尺寸存进 UserDefaults 再读回来")
    func expandedSizeRoundTrips() {
        let suite = "notch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.expandedSize == nil)
        preferences.expandedSize = (720, 480)
        #expect(preferences.expandedSize?.width == 720)
        #expect(preferences.expandedSize?.contentHeight == 480)
    }

    /// 没存过的时候 `double(forKey:)` 返回 0。当成「有过一个 0×0 的岛」
    /// 会把岛缩成一条线。
    @Test("从没存过时返回 nil，而不是一个 0 尺寸")
    func absentSizeIsNil() {
        let suite = "notch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults: defaults).expandedSize == nil)
    }

    /// 内容区高度的口径 2026-08-02 变了（用量条那 22pt 从 chrome 挪进来）。
    /// 老版本存下的数是**旧口径**的，直接拿来用会让岛当场矮 22pt ——
    /// 用户什么都没动，岛却变了。读的时候补一次。
    @Test("老版本存的高度读出来自动补上那 22pt")
    func oldHeightIsMigratedOnce() {
        let suite = "notch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // 老版本写下的样子：只有两个尺寸键，没有迁移标记。
        defaults.set(720.0, forKey: "expandedWidth")
        defaults.set(480.0, forKey: "expandedContentHeight")

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.expandedSize?.contentHeight == 480 + Preferences.usageBarReclaim)
        // **只补一次。** 每读一次加 22 的话，岛会一次比一次高。
        #expect(preferences.expandedSize?.contentHeight == 480 + Preferences.usageBarReclaim)
    }

    /// 新装的 app 从来没有旧口径的值，存完再读不该被加料。
    @Test("新存进去的高度不会再被补")
    func freshHeightIsNotMigrated() {
        let suite = "notch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        preferences.expandedSize = (720, 480)
        #expect(preferences.expandedSize?.contentHeight == 480)
    }
}
