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

    @Test("等待中的会话算作待处理，但不算在跑")
    func waitingCountsAsUnreadNotRunning() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugAskOldestRunning()
        #expect(m.context.runningCount == 0)
        #expect(m.context.unreadCount == 1)
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

    // MARK: - 模式

    @Test("⇧Tab 依次轮换四档模式，转一圈回到默认")
    func cycleModeWrapsAround() {
        let m = model()
        m.debugStartSession(named: "a")
        #expect(m.selectedTab?.usage.mode == .manual)

        var seen: [SessionUsage.Mode] = []
        for _ in SessionUsage.Mode.allCases {
            m.cycleMode()
            seen.append(m.selectedTab!.usage.mode)
        }
        #expect(Set(seen).count == SessionUsage.Mode.allCases.count)
        #expect(seen.last == .manual)
    }

    @Test("模式档位与 Claude Code 自己的选单一致，不翻译")
    func modesMatchClaudeCode() {
        // 岛显示的档位必须和用户在终端里看到的是同一个词。
        #expect(SessionUsage.Mode.allCases.map(\.label)
                == ["Manual", "Accept edits", "Plan", "Auto"])
    }

    @Test("一个会话都没有时轮换模式不炸")
    func cycleModeWithoutSessionIsHarmless() {
        let m = model()
        m.cycleMode()
        #expect(m.tabs.isEmpty)
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
