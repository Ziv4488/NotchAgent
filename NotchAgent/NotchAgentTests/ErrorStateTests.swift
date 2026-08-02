//
//  ErrorStateTests.swift
//  NotchAgentTests
//
//  会话没了的时候，岛得说清楚是「结束了」还是「出事了」。
//

import Foundation
import SwiftUI
import Testing
@testable import NotchAgent

/// 计划 4.1 的错误态：**PTY 非零退出要显示退出码**。
///
/// 改之前 `apply(_ status:)` 只给 `.failed` 留文案，`.finished(1)` 和
/// `.finished(0)` 在界面上是同一句「会话已结束。」—— claude 崩了、参数写错了
/// 当场退出、正常 `/exit`，用户看到的一模一样，而这三种该做的事完全不同。
@Suite("会话结束时说的那句话")
@MainActor
struct SessionEndNoteTests {

    @Test("正常退出不多话")
    func cleanExitSaysNothingExtra() {
        #expect(IslandModel.endNote(for: .finished(0)) == nil)
        #expect(!IslandModel.isAbnormal(.finished(0)))
    }

    @Test("非零退出码要写出来")
    func nonZeroExitShowsTheCode() throws {
        let note = try #require(IslandModel.endNote(for: .finished(1)))
        #expect(note.contains("1"))
        #expect(IslandModel.isAbnormal(.finished(1)))
    }

    /// 128 以上是被信号杀的（`SessionStatus.fromWaitStatus` 就是这么编码的）。
    /// 直接甩一个「退出码 143」给用户没有意义 —— 说「被终止（信号 15）」
    /// 他才知道不是自己的代码有问题，是有人把它杀了。
    @Test("被信号杀掉的换算成信号号", arguments: [
        (Int32(128 + SIGTERM), "15"), (Int32(128 + SIGKILL), "9"),
    ])
    func signalsAreDecoded(code: Int32, signal: String) throws {
        let note = try #require(IslandModel.endNote(for: .finished(code)))
        #expect(note.contains(signal))
        #expect(!note.contains("\(code)"), "别把 143 原样甩出来")
    }

    @Test("崩了就用崩的原因当文案")
    func failureKeepsItsReason() {
        #expect(IslandModel.endNote(for: .failed("进程异常中断")) == "进程异常中断")
        #expect(IslandModel.isAbnormal(.failed("进程异常中断")))
    }

    /// 内容区靠 `endedAbnormally` 决定画不画那个琥珀色警告标、
    /// 按钮写「重新启动」还是「继续上次会话」。
    @Test("非零退出落到 tab 上：标成异常，并带着退出码")
    func abnormalExitLandsOnTheTab() throws {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "崩了的")
        let id = model.tabs[0].id

        model.apply(.finished(2), to: id)

        let tab = try #require(model.tabs.first)
        #expect(tab.status == .ended)
        #expect(tab.isDetached)
        #expect(tab.endedAbnormally)
        #expect(tab.activity?.contains("2") == true)
    }

    @Test("正常退出的 tab 不该被标成异常")
    func cleanExitLandsQuietly() throws {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "正常结束的")
        let id = model.tabs[0].id

        model.apply(.finished(0), to: id)

        let tab = try #require(model.tabs.first)
        #expect(tab.status == .ended)
        #expect(!tab.endedAbnormally)
        #expect(tab.activity == nil)
    }
}

/// spec 6.4：hook 通道断了就降级成「运行中（无详情）」，PTY 交互不受影响。
///
/// 这件事以前只写进 `Logger` —— 只有开着 Console.app 的人看得见。
/// 用户那边的表现是终端一切正常、但收起态永远只有项目名，看起来像功能坏了。
@Suite("hook 通道断了的降级")
@MainActor
struct HookDegradationTests {

    private func runningTab(activity: String?) -> IslandTab {
        IslandTab(title: "refactor-auth", kind: .cli, status: .running,
                  accent: .red, activity: activity)
    }

    @Test("通道好着的时候，没有进度就退回项目名")
    func healthyChannelFallsBackToTheTitle() {
        #expect(StatusBand.line(for: runningTab(activity: nil), hookDegraded: false)
                == "refactor-auth")
    }

    /// **这条是降级的全部意义。** 退回项目名的话，「在跑」和「没在跑」
    /// 在收起态长得一模一样，用户只会以为岛坏了。
    @Test("通道断了就说「运行中（无详情）」")
    func degradedChannelSaysSo() {
        #expect(StatusBand.line(for: runningTab(activity: nil), hookDegraded: true)
                == "运行中（无详情）")
    }

    @Test("有真的进度时，通道状态不影响那一行")
    func realActivityAlwaysWins() {
        for degraded in [true, false] {
            #expect(StatusBand.line(for: runningTab(activity: "读 session.ts"),
                                     hookDegraded: degraded) == "读 session.ts")
        }
    }

    @Test("没在跑的 tab 一律显示项目名")
    func idleTabsShowTheTitle() {
        let tab = IslandTab(title: "refactor-auth", kind: .cli, status: .done,
                            accent: .red, activity: "读 session.ts")
        #expect(StatusBand.line(for: tab, hookDegraded: true) == "refactor-auth")
    }

    /// 提示图标占着 tab 条的位置，notice 态的岛宽是按 tab 条量出来的 ——
    /// 不算进去的话末尾的 ＋ 正好被岛的轮廓切掉半个。
    @Test("降级提示的宽度算进 tab 条")
    func theHintIsMeasured() {
        let tabs = [IslandTab(title: "a", kind: .cli, status: .running, accent: .red)]
        #expect(TabStrip.measuredWidth(for: tabs, hookDegraded: true)
                > TabStrip.measuredWidth(for: tabs, hookDegraded: false))
    }
}
