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

    /// §1.3 / §1.4：菜单栏上**能点的东西全在两端** —— 左边一排 app 菜单，
    /// 右边一排状态项加时钟。岛长在正中间，只要它两侧离屏幕边够远，那些东西就永远点得到。
    ///
    /// 岛盖住的是中间那段，那儿本来什么都没有。这是 spec 3.1 认下的代价，
    /// 不是 bug —— 这条守的是「别再往两边长到把菜单栏两端也吃掉」。
    @Test("岛两侧都够不着菜单栏的左右两端", arguments: allGeometries)
    func islandNeverReachesTheMenuBarEnds(name: String, geometry: FakeScreenGeometry) {
        let metrics = IslandMetrics(geometry: geometry)
        let screen = geometry.screenFrame.width
        for state in IslandState.allCases {
            let width = metrics.size(for: state).width
            let margin = (screen - width) / 2
            #expect(margin > 300,
                    "\(name) 的 \(state) 态两侧只剩 \(Int(margin))pt，菜单栏两端要被盖了")
        }
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

    @Test("expanded 高度 = 菜单栏 + tab 条 + 内容区 + 拆掉的输入框那 44")
    func expandedHeight() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let c = metrics.constants
            let expected = geometry.menuBarHeight + c.tabStripHeight
                + c.contentHeight + c.retiredInputBarHeight
            #expect(metrics.size(for: .expanded).height == expected, "\(name)")
        }
    }

    /// **用量条拆掉时留下的那 22pt，只是换了个地方待着，不是被删了。**
    ///
    /// 它原来算在 chrome 里（`usageBarHeight`），2026-08-02 挪进了 `contentHeight`。
    /// 挪动的全部要求就是：岛长出来还是那么高。这条把两个口径下的默认高度
    /// 钉死在一起 —— 谁再顺手把 342 改回 320，这里立刻红。
    @Test("挪那 22pt 之前之后，展开态默认高度一样")
    func reclaimingTheUsageBarKeepsTheHeight() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            // 旧口径：菜单栏 + 34 + 22(用量条) + 44 + 320(内容区)
            let old = geometry.menuBarHeight + 34 + 22 + 44 + 320
            #expect(metrics.size(for: .expanded).height == old, "\(name)")
        }
    }

    /// 最矮那一档也不能因为换口径矮下去。
    @Test("拖到最矮时，岛的高度和换口径之前一样")
    func shortestExpandedIsUnchanged() {
        let geometry = FakeScreenGeometry.macBook14
        let metrics = IslandMetrics(geometry: geometry,
                                    expandedContentHeight: IslandMetrics(geometry: geometry)
                                        .expandedContentHeightRange.lowerBound)
        #expect(metrics.size(for: .expanded).height == geometry.menuBarHeight + 34 + 22 + 44 + 160)
    }

    /// §8.5b：会话从「在跑」变成「已结束」，岛的**总高度一点都不变**。
    ///
    /// 在跑的时候画的是终端，结束之后换成「继续上次会话」那张卡 —— 两块的
    /// 高度是同一个（内容区 `maxHeight: .infinity`），岛不该跟着抽一下。
    ///
    /// 这条 2026-08-04 之前守的是另一件事：那时结束之后底下会多出一条输入框，
    /// 它那 44pt 由内容区让出来、不加在岛上。输入框现在拆了（见
    /// `IslandConstants.retiredInputBarHeight`），44pt 还在总高里，
    /// 这条守的东西没变 —— 状态一变，高度一个像素都不许动。
    @Test("会话结束时岛的总高度不变")
    func endingASessionKeepsTheIslandHeight() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        // 用点击进展开态，不用 `previewState(.expanded)` —— 那个会**再造一个在跑的
        // 会话**，于是「把这个会话结束掉」之后仍有别的在跑，要测的那个变化根本没发生。
        model.send(.click)
        let before = model.size

        model.apply(.finished(0), to: model.tabs[0].id)
        #expect(model.state == .expanded, "结束事件不该把展开态打断")
        #expect(model.size == before, "岛从 \(before) 变成了 \(model.size)")
    }

    @Test("拖大内容区，expanded 只长内容区那一截，其余高度不动")
    func expandedGrowsOnlyByContentHeight() {
        let geometry = FakeScreenGeometry.macBook14
        let base = IslandMetrics(geometry: geometry)
        let taller = IslandMetrics(geometry: geometry, expandedContentHeight: base.expandedContentHeight + 120)
        #expect(taller.size(for: .expanded).height == base.size(for: .expanded).height + 120)
        #expect(taller.expandedChromeHeight == base.expandedChromeHeight)
    }

    @Test("拖拽后的尺寸如实反映到岛主体上")
    func resizedSizeFlowsIntoExpanded() {
        let geometry = FakeScreenGeometry.macBook14
        let metrics = IslandMetrics(geometry: geometry, expandedWidth: 820, expandedContentHeight: 500)
        #expect(metrics.size(for: .expanded).width == 820)
        #expect(metrics.size(for: .expanded).height == metrics.expandedChromeHeight + 500)
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

    @Test("有刘海：底部 16、内凹 8，四态一致")
    func radiiOnNotchedScreens() {
        for geometry in [FakeScreenGeometry.macBook14, .macBook16] {
            let metrics = IslandMetrics(geometry: geometry)
            for state in IslandState.allCases {
                let radii = metrics.cornerRadii(for: state)
                #expect(radii.bottom == 16)
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
                #expect(metrics.cornerRadii(for: state).bottom == 16)
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

    @Test("窗口比岛能长到的最大宽度左右各再宽出一个内凹半径，圆弧才不会被切掉")
    func containerLeavesRoomForInvertedArcs() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            #expect(metrics.containerFrame.width == metrics.maxExpandedSize.width + 16, "\(name)")
        }
    }

    @Test("面板尺寸与当前拖拽尺寸无关 —— 拖动时窗口一动不动，才不会闪")
    func containerIsIndependentOfCurrentSize() {
        let geometry = FakeScreenGeometry.macBook14
        let small = IslandMetrics(geometry: geometry, expandedWidth: 420, expandedContentHeight: 160)
        let large = IslandMetrics(geometry: geometry, expandedWidth: 900, expandedContentHeight: 600)
        #expect(small.containerFrame == large.containerFrame)
    }

    @Test("面板放得下拖到最大的岛")
    func containerFitsMaximumDrag() {
        for (name, geometry) in allGeometries {
            let metrics = IslandMetrics(geometry: geometry)
            let maxed = IslandMetrics(geometry: geometry,
                                      expandedWidth: metrics.expandedWidthRange.upperBound,
                                      expandedContentHeight: metrics.expandedContentHeightRange.upperBound)
            let size = maxed.size(for: .expanded)
            #expect(size.width <= metrics.containerFrame.width, "\(name)")
            #expect(size.height <= metrics.containerFrame.height, "\(name)")
        }
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
