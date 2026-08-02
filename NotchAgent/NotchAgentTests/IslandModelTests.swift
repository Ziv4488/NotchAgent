//
//  IslandModelTests.swift
//  NotchAgentTests
//
//  模型侧：等待态、拖拽尺寸、模式轮换、状态带左右分区。
//

import Testing
import CoreGraphics
import AppKit
@testable import NotchAgent

@MainActor
struct IslandModelTests {

    private func model() -> IslandModel {
        IslandModel(geometry: FakeScreenGeometry.macBook14)
    }

    // MARK: - 等待你回话

    @Test("会话停下来问你，岛要进 notice —— 卡住却不出声是最坏的情况")
    func waitingRaisesNotice() {
        let m = model()
        m.debugStartSession(named: "refactor-auth")
        #expect(m.state == .running)

        m.debugAskOldestRunning()
        #expect(m.state == .notice)
        #expect(m.tabs[0].status == .waiting)
    }

    /// 一个正等着你回话的会话是**活的**。收起时落到 idle 等于说
    /// 「什么都没在进行」，那是假话 —— 它就卡在那儿等你。
    @Test("等待中的会话算在跑，未读来自询问本身")
    func waitingCountsAsRunning() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugAskOldestRunning()
        #expect(m.context.runningCount == 1)
        #expect(m.context.unreadCount == 1)
    }

    /// 用户报的 bug：询问弹出来 → 展开 → 答完 → 收起，岛永远停在 notice，
    /// 再也回不到 idle。
    ///
    /// 两处原因，都在这条路上：
    /// 一是只有 `.tabOpened` 清未读，而**通知弹出来时那个 tab 本来就是选中的**，
    /// 用户直接点岛开始处理，根本不会去点 tab —— 最常走的那条路清不掉未读；
    /// 二是 `unreadCount` 还把 `.waiting` 算一份，那一份没有任何人负责清。
    @Test("询问 → 点开岛 → 答完 → 收起，岛回得到 idle")
    func answeringAPromptLetsTheIslandSettle() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugAskOldestRunning()
        #expect(m.state == .notice)

        // 用户点岛展开。注意：**没有点 tab** —— 它本来就是选中的。
        m.send(.click)
        #expect(m.state == .expanded)
        #expect(m.tabs[0].unread == false)

        // 在终端里答完，这一轮结束。
        m.apply(SessionSignal(status: .idle, demandsAttention: true), to: m.tabs[0].id)
        m.send(.dismiss)
        #expect(m.state == .idle)
    }

    /// 人正看着这个 tab 的时候来的事，不该在他收起岛之后变成一条等着他的未读。
    @Test("看着的时候完成，不留未读")
    func finishingWhileWatchedLeavesNothingUnread() {
        let m = model()
        m.debugStartSession(named: "a")
        m.selectTab(m.tabs[0].id)
        #expect(m.state == .expanded)

        m.apply(SessionSignal(status: .idle, demandsAttention: true), to: m.tabs[0].id)
        #expect(m.tabs[0].unread == false)
        m.send(.dismiss)
        #expect(m.state == .idle)
    }

    /// 没看的那个不能跟着一起清 —— 点开 A 不代表 B 的通知也处理过了。
    @Test("只清看着的那个 tab 的未读，别人的留着")
    func onlyTheSelectedTabIsMarkedRead() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugStartSession(named: "b")
        for tab in m.tabs {
            m.apply(SessionSignal(status: .idle, demandsAttention: true), to: tab.id)
        }
        #expect(m.tabs.filter(\.unread).count == 2)

        m.selectTab(m.tabs[1].id)
        #expect(m.tabs[0].unread)
        #expect(m.tabs[1].unread == false)
    }

    // MARK: - 计时

    /// 「时间跟实际运行没有任何关系」—— 因为它从会话起来那一刻开始算，
    /// 而不是从这一轮开始算。计时要在每个回合开始时归零。
    @Test("每个回合开始都把计时归零")
    func timerRestartsEachTurn() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id

        m.apply(SessionSignal(status: .idle), to: id)      // 上一轮结束
        let afterStop = m.tabs[0].startedAt
        m.apply(SessionSignal(status: .running), to: id)   // 新一轮开始
        #expect(m.tabs[0].startedAt > afterStop)
    }

    /// 一轮之内工具事件密集，每条都归零的话计时永远在 0 附近跳。
    @Test("一轮之内的工具事件不动计时")
    func toolEventsDoNotRestartTheTimer() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.apply(SessionSignal(status: .running), to: id)
        let started = m.tabs[0].startedAt

        m.apply(SessionSignal(status: .running, activity: "读 a.swift"), to: id)
        m.apply(SessionSignal(status: .running), to: id)
        #expect(m.tabs[0].startedAt == started)
    }

    @Test("右侧计时只跟在跑的会话，全停下就没有计时")
    func timedTabFollowsRunningOnly() {
        let m = model()
        m.debugStartSession(named: "a")
        #expect(m.timedTab != nil)

        m.debugAskOldestRunning()
        #expect(m.timedTab == nil)
    }

    // MARK: - 拖拽尺寸

    @Test("拖拽尺寸被夹在允许范围内，拖不出屏幕也拖不到不可用")
    func resizeIsClamped() {
        let m = model()
        m.resizeExpanded(width: 10_000, contentHeight: 10_000)
        #expect(m.expandedWidth == m.expandedWidthRange.upperBound)
        #expect(m.expandedContentHeight == m.expandedContentHeightRange.upperBound)

        m.resizeExpanded(width: 0, contentHeight: 0)
        #expect(m.expandedWidth == m.expandedWidthRange.lowerBound)
        #expect(m.expandedContentHeight == m.expandedContentHeightRange.lowerBound)
    }

    @Test("尺寸真的变了才通知窗口层，拖到边界后不该继续刷 frame")
    func resizeNotifiesOnlyOnChange() {
        let m = model()
        var calls = 0
        m.onExpandedSizeChanged = { calls += 1 }

        m.resizeExpanded(width: 600, contentHeight: 360)
        #expect(calls == 1)

        m.resizeExpanded(width: 600, contentHeight: 360)
        #expect(calls == 1)
    }

    @Test("拖大后岛的尺寸跟上，但承载它的面板一动不动")
    func resizeFlowsIntoIslandButNotPanel() {
        let m = model()
        let panel = m.metrics.containerFrame
        m.resizeExpanded(width: 700, contentHeight: 420)
        #expect(m.metrics.size(for: .expanded).width == 700)
        // 面板跟着变就会看见一帧错位，那正是拖动闪烁的来源。
        #expect(m.metrics.containerFrame == panel)
    }

    @Test("岛主体的四条边按当前尺寸算，拖拽手柄靠它做绝对定位")
    func expandedEdgesTrackCurrentSize() {
        let m = model()
        let screen = m.geometry.screenFrame
        m.resizeExpanded(width: 700, contentHeight: 420)
        let edges = m.expandedEdges
        #expect(edges.centerX == screen.midX)
        #expect(edges.topY == screen.maxY)
        #expect(edges.topY - edges.bottomY == m.metrics.size(for: .expanded).height)
    }

    @Test("可拖范围的下限放得下终端，上限留得住桌面")
    func resizeRangesAreSane() {
        let m = model()
        #expect(m.expandedWidthRange.lowerBound >= 400)
        #expect(m.expandedWidthRange.upperBound < m.geometry.screenFrame.width)
        #expect(m.expandedContentHeightRange.upperBound + m.metrics.expandedChromeHeight
                < m.geometry.screenFrame.height)
    }

    // MARK: - 改名

    @Test("改名落到 tab 上")
    func renamesTab() {
        let m = model()
        m.debugStartSession(named: "Agent灵动岛")
        let id = m.tabs[0].id
        m.renameTab(id, to: "重构鉴权")
        #expect(m.tabs[0].title == "重构鉴权")
    }

    /// 空名字会让 tab 芯片缩成只剩一个图标，谁都点不中它。
    /// 保留原名比接受一个点不中的 tab 好。
    @Test("空白名字不接受，原名留着", arguments: ["", "   ", "\n\t "])
    func rejectsBlankNames(blank: String) {
        let m = model()
        m.debugStartSession(named: "原名")
        m.renameTab(m.tabs[0].id, to: blank)
        #expect(m.tabs[0].title == "原名")
    }

    @Test("首尾空白会被去掉 —— 用户看不见它，却会撑宽 tab")
    func trimsWhitespace() {
        let m = model()
        m.debugStartSession(named: "a")
        m.renameTab(m.tabs[0].id, to: "  重构  ")
        #expect(m.tabs[0].title == "重构")
    }

    @Test("给不存在的 tab 改名不炸")
    func renameUnknownTabIsHarmless() {
        let m = model()
        m.debugStartSession(named: "a")
        m.renameTab(UUID(), to: "别的")
        #expect(m.tabs[0].title == "a")
    }

    /// 改名后的宽度要立刻反映到 tab 条上 —— notice 态的岛宽就是按它算的，
    /// 对不上会出现「字比岛长」。
    @Test("改完名字，tab 条量出来的宽度跟着变")
    func renameChangesStripWidth() {
        let m = model()
        m.debugStartSession(named: "a")
        let before = m.tabStripWidth
        m.renameTab(m.tabs[0].id, to: "一个相当长的会话名字")
        #expect(m.tabStripWidth > before)
    }

    // MARK: - 中断

    @Test("按停止：会话停下，但不标未读 —— 人就在跟前看着，不该再催他")
    func interruptStopsWithoutNagging() {
        let m = model()
        m.debugStartSession(named: "a")
        m.send(.click)
        m.interruptSelectedTask()
        #expect(m.tabs[0].status == .done)
        #expect(m.tabs[0].unread == false)
        #expect(m.state == .expanded)   // 自己按的停止，不该把岛收掉
    }

    @Test("没在跑的会话按停止是空操作")
    func interruptIgnoresIdleSession() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugFinishOldestRunning()
        let before = m.tabs
        m.interruptSelectedTask()
        #expect(m.tabs == before)
    }

    // MARK: - 状态带左右分区

    @Test("左右两半等宽，中间原样留给刘海 —— 信息绝不能压到刘海底下")
    func statusBandReservesTheNotch() {
        for (total, gap) in [(329.0, 185.0), (560.0, 185.0), (200.0, 0.0)] {
            let side = StatusBand.sideWidth(totalWidth: total, notchGap: gap)
            #expect(side * 2 + gap == total)
            #expect(side >= 0)
        }
    }

    @Test("岛比刘海还窄时侧宽夹到 0，不会算出负数把布局搞乱")
    func statusBandSideWidthNeverNegative() {
        #expect(StatusBand.sideWidth(totalWidth: 100, notchGap: 185) == 0)
    }

    @Test("idle 空态的 app 名放得下，不会折成两行")
    func idleEmptyLabelFitsOnOneLine() {
        // 曾经真的折过：左半边只有 54pt，而 "NotchAgent" 要 64pt。
        let geometry = FakeScreenGeometry.macBook14
        let metrics = IslandMetrics(geometry: geometry)
        let side = StatusBand.sideWidth(totalWidth: metrics.size(for: .idle).width,
                                        notchGap: geometry.notchWidth ?? 0)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let label = ("NotchAgent" as NSString).size(withAttributes: [.font: font]).width
        // 10 是 leading padding。
        #expect(side - 10 >= label)
    }

    // MARK: - 计时格式

    @Test("计时：不满一小时是 m:ss，过了一小时补上小时位",
          arguments: [(0.0, "0:00"), (9.0, "0:09"), (74.0, "1:14"),
                      (3599.0, "59:59"), (3600.0, "1:00:00"), (3725.0, "1:02:05")])
    func elapsedFormat(seconds: Double, expected: String) {
        #expect(ElapsedLabel.format(seconds) == expected)
    }

    @Test("负数时长按 0 算 —— 系统时钟回拨不该显示乱码")
    func elapsedFormatClampsNegative() {
        #expect(ElapsedLabel.format(-42) == "0:00")
    }
}
