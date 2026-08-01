//
//  CloseTabConfirmTests.swift
//  NotchAgentTests
//
//  关一个还在跑的 tab 之前要先问。
//

import Foundation
import Testing
@testable import NotchAgent

/// 用户 2026-08-02：「如果已经有任务或者打开 cc，关闭 tab 时需要弹窗提醒」。
///
/// 和退出确认是同一件事的两个尺度 —— 那一下点下去，一个正在干活的会话就没了。
/// 已经结束的 tab 不问：那一下没有代价，`--resume` 还接得回去。
@Suite("关 tab 前的确认")
@MainActor
struct CloseTabConfirmTests {

    /// 造一个真起了进程的会话，并把它和 tab 绑成同一个 id。
    /// 用 `/bin/sh` 顶替 `claude` —— 要测的是「还活着就得问」，跟跑的是谁无关。
    private func modelWithLiveTab() throws -> (IslandModel, IslandTab) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        // **别写用户真的那份 tabs.json**：closeTab 会顺手持久化一次。
        model.tabStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-test-tabs-\(UUID().uuidString).json")

        let runtime = SessionRuntime()
        model.attach(runtime: runtime)
        model.debugStartSession(named: "还在跑的")
        let tab = try #require(model.tabs.last)

        let session = CLISession(id: tab.id, title: tab.title, workingDirectory: nil,
                                 launch: .init(executable: "/bin/sh",
                                               arguments: ["-c", "sleep 30"],
                                               searchPath: "/usr/bin:/bin",
                                               settingsURL: nil))
        // 收尾时别真去 pgrep 系统里的进程。
        session.reaper.find = { _ in [] }
        runtime.store.add(session)
        try session.start()
        return (model, tab)
    }

    @Test("会话还活着，点关闭要先问")
    func asksBeforeClosingALiveTab() throws {
        let (model, tab) = try modelWithLiveTab()
        var asked: [String] = []
        model.confirmCloseLiveTab = { asked.append($0.title); return false }

        model.closeTab(tab.id)

        #expect(asked == ["还在跑的"])
        // 答了「取消」，tab 得原封不动留着。
        #expect(model.tabs.contains { $0.id == tab.id })
        #expect(model.hasLiveSession(tab.id))
    }

    @Test("答了确认才真的关")
    func closesWhenConfirmed() throws {
        let (model, tab) = try modelWithLiveTab()
        model.confirmCloseLiveTab = { _ in true }

        model.closeTab(tab.id)

        #expect(!model.tabs.contains { $0.id == tab.id })
    }

    /// 进程已经退了的 tab（岛上显示「会话已结束 · 继续上次会话」）没有代价，
    /// 每关一个都弹一次框是骚扰。
    @Test("已经结束的 tab 不问，直接关")
    func doesNotAskForADeadTab() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "已经结束的")
        let id = model.tabs[0].id
        var asked = false
        model.confirmCloseLiveTab = { _ in asked = true; return false }

        model.closeTab(id)

        #expect(!asked)
        #expect(model.tabs.isEmpty)
    }
}
