//
//  AttachGeometryTests.swift
//  NotchAgentTests
//
//  贴附的窗口该摆在哪：内容区的屏幕坐标，以及 AppKit ↔ AX 那一下翻转。
//

import CoreGraphics
import Foundation
import Testing
@testable import NotchAgent

@Suite("贴附的几何")
struct AttachGeometryTests {

    private func metrics(_ geometry: ScreenGeometryProviding = FakeScreenGeometry.macBook14)
    -> IslandMetrics {
        IslandMetrics(geometry: geometry)
    }

    // MARK: - 内容区在屏幕上的哪儿

    /// 贴附的窗口占的必须**正好**是 CLI tab 内容区那块地方 ——
    /// 不然两种 tab 之间来回切，岛的轮廓会跳一下。
    @Test("内容区紧贴在状态带 + tab 条下面，宽度就是岛宽")
    func contentRectSitsUnderTheChrome() {
        let m = metrics()
        let island = m.size(for: .expanded)
        let rect = m.contentRectOnScreen
        let geometry = FakeScreenGeometry.macBook14

        #expect(rect.width == island.width)
        // 上沿：屏幕顶 - 状态带 - tab 条
        #expect(rect.maxY == geometry.screenTopY - geometry.menuBarHeight - m.constants.tabStripHeight)
        // 下沿：和岛的底边齐平
        #expect(rect.minY == geometry.screenTopY - island.height)
        // 水平居中在刘海中线上
        #expect(rect.midX == geometry.islandCenterX)
    }

    /// 岛的总高一分为二：状态带 + tab 条归岛自己画，剩下的是内容区。
    /// 少一个像素窗口就压不满，多一个就盖住 tab 条。
    @Test("bandAndTabsHeight 加上内容区高度正好是岛的总高")
    func chromeAndContentAddUpToTheIsland() {
        let m = metrics()
        #expect(m.bandAndTabsHeight + m.contentRectOnScreen.height == m.size(for: .expanded).height)
    }

    // MARK: - 窗口四周那圈黑边（用户 08-07）

    /// 窗口原来是直接顶着岛的下沿铺满的，用户说「感觉不是一个东西」。
    /// 现在四周各让出 `attachBezel`，岛在外面框住它。
    @Test("贴附的窗口比内容区四周各小一圈")
    func theWindowIsInsetFromTheContentArea() {
        let m = metrics()
        let bezel = m.constants.attachBezel
        let content = m.contentRectOnScreen
        let window = m.attachedWindowRect

        #expect(bezel > 0)
        #expect(window.minX == content.minX + bezel)
        #expect(window.maxX == content.maxX - bezel)
        #expect(window.minY == content.minY + bezel)
        #expect(window.maxY == content.maxY - bezel)
    }

    /// **岛挖的洞和窗口摆的位置必须是同一块地方。** 一边是岛画布坐标（原点左上），
    /// 一边是屏幕坐标（原点左下），两边分开算，迟早有一处对不上 ——
    /// 而对不上的表现是「看着有个洞，点下去没反应」，或者反过来「窗口边上一条缝
    /// 点不动」。这条把两套坐标接起来对一遍。
    @Test("洞和窗口说的是同一块地方")
    func theHoleAndTheWindowAgree() {
        let geometry = FakeScreenGeometry.macBook14
        let m = metrics()
        let island = m.size(for: .expanded)
        let hole = m.attachedHoleInIsland
        let window = m.attachedWindowRect

        #expect(hole.size == window.size)
        // 洞离岛顶多远 == 窗口上沿离屏幕顶多远（岛的顶边就压在屏幕顶上）。
        #expect(hole.minY == geometry.screenTopY - window.maxY)
        // 洞离岛体左沿多远 == 窗口左沿离岛体左沿多远。
        // 画布左右各比岛体多出一个内凹半径，减掉它才是岛体自己的左沿。
        let inverted = m.cornerRadii(for: .expanded).inverted
        #expect(hole.minX - inverted == window.minX - (geometry.islandCenterX - island.width / 2))
    }

    /// 洞必须整个落在岛体里 —— 探出去就是在屏幕上开了个透明缺口。
    @Test("洞在 tab 条下面，四周都还有岛")
    func theHoleStaysInsideTheIsland() {
        let m = metrics()
        let island = m.size(for: .expanded)
        let hole = m.attachedHoleInIsland
        let inverted = m.cornerRadii(for: .expanded).inverted

        #expect(hole.minY > m.bandAndTabsHeight)
        #expect(hole.maxY < island.height)
        #expect(hole.minX > inverted)
        #expect(hole.maxX < inverted + island.width)
    }

    /// 拖拽调尺寸时窗口要跟着走，所以这个矩形必须跟着 expanded 尺寸变。
    @Test("拖宽拖高之后内容区跟着变")
    func contentRectFollowsTheDrag() {
        let base = metrics().contentRectOnScreen
        let bigger = IslandMetrics(geometry: FakeScreenGeometry.macBook14,
                                   expandedWidth: 900,
                                   expandedContentHeight: 600).contentRectOnScreen

        #expect(bigger.width == 900)
        #expect(bigger.width > base.width)
        #expect(bigger.height > base.height)
        // 上沿不动 —— 状态带和 tab 条的高度跟拖拽无关。
        #expect(bigger.maxY == base.maxY)
    }

    /// 外接屏的 `screenFrame` 原点不在 (0,0)，还可能是负的。
    /// 内容区必须跟着那块屏走，不能悄悄回到主屏上。
    @Test("外接屏上内容区仍落在那块屏里")
    func contentRectStaysOnItsScreen() {
        let external = FakeScreenGeometry.external
        let rect = IslandMetrics(geometry: external).contentRectOnScreen

        #expect(external.screenFrame.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))
        #expect(rect.midX == external.screenFrame.midX)
    }

    // MARK: - 两套坐标之间那一下

    /// **翻错了不会报错，只会把窗口放到屏幕另一头。** 两边都是 CGRect，
    /// 编译器帮不上忙，只能靠这条钉着。
    @Test("翻成 AX 坐标：贴着屏幕顶的矩形，y 应该接近 0")
    func topLeftPutsTheTopOfScreenNearZero() {
        // 主屏 1512×982，原点左下。岛顶边贴着屏幕上沿 y=982。
        let primaryTopY: CGFloat = 982
        let atTop = CGRect(x: 100, y: 982 - 300, width: 560, height: 300)

        let ax = AXCoordinates.topLeft(atTop, primaryTopY: primaryTopY)
        #expect(ax.origin.y == 0)          // 贴着屏幕顶 → AX 里就是 0
        #expect(ax.origin.x == 100)        // x 不变
        #expect(ax.size == atTop.size)     // 尺寸不变
    }

    @Test("往下挪的矩形，AX 里的 y 变大")
    func axYGrowsDownward() {
        let high = CGRect(x: 0, y: 800, width: 100, height: 100)
        let low = CGRect(x: 0, y: 200, width: 100, height: 100)

        let axHigh = AXCoordinates.topLeft(high, primaryTopY: 982)
        let axLow = AXCoordinates.topLeft(low, primaryTopY: 982)
        // AppKit 里 high 在上（y 大），AX 里它该在上（y 小）。
        #expect(axHigh.origin.y < axLow.origin.y)
    }

    @Test("翻过去再翻回来，回到原样")
    func flipIsItsOwnInverse() {
        let rect = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let back = AXCoordinates.bottomLeft(AXCoordinates.topLeft(rect, primaryTopY: 982),
                                            primaryTopY: 982)
        #expect(back == rect)
    }

    /// 副屏在主屏**上方**时它的 AppKit y 超过主屏顶边，翻过去 AX 的 y 是负的 ——
    /// 这是对的，不是 bug。写条测试免得将来有人「顺手」给它加个 max(0,…)。
    @Test("主屏上方的副屏，AX 坐标是负的")
    func screensAboveThePrimaryGoNegative() {
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        let ax = AXCoordinates.topLeft(above, primaryTopY: 982)
        #expect(ax.origin.y == -1080)
    }
}
