//
//  IslandMetricsTests.swift
//  NotchAgentTests
//
//  四种屏幕几何 × 四个状态的尺寸与圆角。
//

import Testing
import CoreGraphics
@testable import NotchAgent

private let allGeometries: [(String, FakeScreenGeometry)] = [
    ("14\"", .macBook14),
    ("16\"", .macBook16),
    ("无刘海", .noNotch),
    ("外接屏", .external),
]

struct IslandMetricsTests {

    // MARK: - 宽度

    @Test("idle 宽度 = 基准宽 + 左右各一份 idleSideBleed")
    func idleWidth() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let base = geometry.notchWidth ?? metrics.constants.fallbackNotchWidth
            #expect(metrics.size(for: .idle).width == base + metrics.constants.idleSideBleed * 2, "\(name)")
        }
    }

    @Test("idle 比 running 窄 —— 闲着和在跑要一眼分得开，但都放得下一行信息")
    func idleIsNarrowerThanRunning() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let idle = metrics.size(for: .idle).width
            let running = metrics.size(for: .running).width
            #expect(idle < running, "\(name)")
            // 每侧固定开销 20pt（内边距 + 圆点 + 间距），再留够约 10 个英文字符。
            #expect(idle - metrics.baseWidth >= 2 * (20 + 50), "\(name)")
        }
    }

    @Test("岛不该比它要盖住的菜单栏还夸张：每侧外延都在 100pt 以内")
    func sideBleedStaysModest() {
        // 岛比刘海宽多少，就永久盖住菜单栏多少（见 spec 3.1 的「代价」）。
        // 这条守住的是「别再变宽」，不是某个具体数字。
        let constants = IslandConstants.default
        #expect(constants.idleSideBleed <= 100)
        #expect(constants.runningSideBleed <= 100)
    }

    @Test("running 宽度 = 基准宽 + 左右各一份 runningSideBleed")
    func runningWidth() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let base = geometry.notchWidth ?? metrics.constants.fallbackNotchWidth
            #expect(metrics.size(for: .running).width
                    == base + metrics.constants.runningSideBleed * 2, "\(name)")
        }
    }

    @Test("无刘海屏用固定宽度基准，不是 0")
    func noNotchFallsBackToFixedWidth() {
        let metrics = IslandMetrics(geometry: FakeScreenGeometry.noNotch)
        #expect(metrics.baseWidth == metrics.constants.fallbackNotchWidth)
        #expect(metrics.size(for: .idle).width > 0)
    }

    @Test("expanded 宽度就是设定的展开宽度，与屏幕几何无关")
    func expandedWidthIsIndependentOfScreen() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry, expandedWidth: 640)
            #expect(metrics.size(for: .expanded).width == 640, "\(name)")
        }
    }

    // MARK: - notice 宽度的三种情形

    @Test("notice 宽度：tab 条比 running 窄时取 running 宽度")
    func noticeTakesRunningWidthWhenTabsAreNarrow() {
        let metrics = IslandMetrics(geometry: FakeScreenGeometry.macBook14)
        let running = metrics.size(for: .running).width
        #expect(metrics.size(for: .notice, tabStripWidth: 100).width == running)
    }

    @Test("notice 宽度：tab 条更宽时被撑开")
    func noticeGrowsWithTabStrip() {
        let metrics = IslandMetrics(geometry: FakeScreenGeometry.macBook14)
        let running = metrics.size(for: .running).width
        let wider = running + 60
        #expect(metrics.size(for: .notice, tabStripWidth: wider).width == wider)
    }

    @Test("notice 宽度：上限是 expanded 宽度")
    func noticeIsCappedAtExpandedWidth() {
        let metrics = IslandMetrics(geometry: FakeScreenGeometry.macBook14, expandedWidth: 560)
        #expect(metrics.size(for: .notice, tabStripWidth: 5000).width == 560)
    }

    // MARK: - 高度

    @Test("idle 与 running 高度等于菜单栏高度")
    func collapsedHeightsMatchMenuBar() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            #expect(metrics.size(for: .idle).height == geometry.menuBarHeight, "\(name)")
            #expect(metrics.size(for: .running).height == geometry.menuBarHeight, "\(name)")
        }
    }

    @Test("notice 高度 = 菜单栏 + tab 条")
    func noticeHeight() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let expected = geometry.menuBarHeight + metrics.constants.tabStripHeight
            #expect(metrics.size(for: .notice).height == expected, "\(name)")
        }
    }

    @Test("expanded 高度 = 菜单栏 + tab 条 + 内容区 + 用量条 + 输入框")
    func expandedHeight() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let c = metrics.constants
            let expected = geometry.menuBarHeight + c.tabStripHeight
                + c.contentHeight + c.usageBarHeight + c.inputBarHeight
            #expect(metrics.size(for: .expanded).height == expected, "\(name)")
        }
    }

    @Test("拖大内容区，expanded 只长内容区那一截，其余高度不动")
    func expandedGrowsOnlyByContentHeight() {
        let geometry = FakeScreenGeometry.macBook14
        let base = IslandMetrics(geometry: geometry)
        let taller = IslandMetrics(geometry: geometry, expandedContentHeight: base.expandedContentHeight + 120)
        #expect(taller.size(for: .expanded).height == base.size(for: .expanded).height + 120)
        #expect(taller.expandedChromeHeight == base.expandedChromeHeight)
    }

    @Test("窗口 frame 跟着拖拽后的尺寸走，岛才不会被切掉")
    func containerFollowsResizedExpanded() {
        let geometry = FakeScreenGeometry.macBook14
        let metrics = IslandMetrics(geometry: geometry, expandedWidth: 820, expandedContentHeight: 500)
        let frame = metrics.containerFrame
        #expect(frame.width == 820 + metrics.constants.invertedCornerRadius * 2)
        #expect(frame.height == metrics.size(for: .expanded).height)
        #expect(frame.maxY == geometry.screenFrame.maxY)
    }

    @Test("高度单调不减：idle ≤ running < notice < expanded")
    func heightsAreMonotonic() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let idle = metrics.size(for: .idle).height
            let running = metrics.size(for: .running).height
            let notice = metrics.size(for: .notice).height
            let expanded = metrics.size(for: .expanded).height
            #expect(idle <= running, "\(name)")
            #expect(running < notice, "\(name)")
            #expect(notice < expanded, "\(name)")
        }
    }

    // MARK: - 圆角

    @Test("有刘海：底部 12、内凹 8，四态一致")
    func radiiOnNotchedScreens() {
        for geometry in [FakeScreenGeometry.macBook14, .macBook16] {
            let metrics = IslandMetrics(geometry: geometry)
            for state in IslandState.allCases {
                let radii = metrics.cornerRadii(for: state)
                #expect(radii.bottom == 12)
                #expect(radii.inverted == 8)
            }
        }
    }

    @Test("无刘海：内凹半径为 0，退化成普通圆角矩形")
    func noInvertedCornersWithoutNotch() {
        for geometry in [FakeScreenGeometry.noNotch, .external] {
            let metrics = IslandMetrics(geometry: geometry)
            for state in IslandState.allCases {
                #expect(metrics.cornerRadii(for: state).inverted == 0)
                #expect(metrics.cornerRadii(for: state).bottom == 12)
            }
        }
    }

    // MARK: - 窗口 frame

    @Test("窗口顶边贴齐屏幕上沿，水平居中于屏幕中线")
    func containerFrameIsAnchoredToScreenTop() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let frame = metrics.containerFrame
            #expect(frame.maxY == geometry.screenFrame.maxY, "\(name)")
            #expect(frame.midX == geometry.screenFrame.midX, "\(name)")
        }
    }

    @Test("窗口比岛主体左右各宽出一个内凹半径，圆弧才不会被切掉")
    func containerLeavesRoomForInvertedArcs() {
        let notched = IslandMetrics(geometry: FakeScreenGeometry.macBook14)
        #expect(notched.containerFrame.width == notched.size(for: .expanded).width + 16)

        let flat = IslandMetrics(geometry: FakeScreenGeometry.noNotch)
        #expect(flat.containerFrame.width == flat.size(for: .expanded).width + 16)
    }

    @Test("窗口容得下最大态，任何状态都不会溢出")
    func containerFitsEveryState() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let container = metrics.containerFrame
            for state in IslandState.allCases {
                let size = metrics.size(for: state, tabStripWidth: 5000)
                #expect(size.width <= container.width, "\(name) \(state)")
                #expect(size.height <= container.height, "\(name) \(state)")
            }
        }
    }

    @Test("外接屏原点不在 (0,0) 时窗口位置仍然跟着走")
    func containerFollowsScreenOrigin() {
        let metrics = IslandMetrics(geometry: FakeScreenGeometry.external)
        let frame = metrics.containerFrame
        #expect(frame.midX == -960)
        #expect(frame.maxY == 1280)
    }
}
