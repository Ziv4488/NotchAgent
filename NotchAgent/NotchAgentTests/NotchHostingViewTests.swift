//
//  NotchHostingViewTests.swift
//  NotchAgentTests
//
//  画布是最大态尺寸的透明窗口，压在屏幕顶部。
//  如果命中测试不收回到岛的轮廓里，透明区会把点击全吞掉 —— app 直接不可用。
//  这是最要命的一条回归，钉死它。
//

import Testing
import AppKit
import SwiftUI
@testable import NotchAgent

@MainActor
private func makeView(state: IslandState) -> NotchHostingView {
    let model = IslandModel.previewModel(state: state)
    let view = NotchHostingView(rootView: IslandShell(model: model))
    view.frame = CGRect(origin: .zero, size: model.metrics.containerFrame.size)
    view.islandGeometry = { (model.size, model.cornerRadii) }
    return view
}

/// `islandPath()` 用的是视图坐标系，而 `NSHostingView` 是 flipped 的。
/// 测试不该假定方向，统一按「距画布顶部多远」来取点。
@MainActor
private func viewPoint(_ view: NSView, fromTop: CGFloat, x: CGFloat) -> CGPoint {
    let y = view.isFlipped ? view.bounds.minY + fromTop : view.bounds.maxY - fromTop
    return CGPoint(x: x, y: y)
}

@MainActor
struct NotchHostingViewTests {

    // MARK: - hitTest（入参是窗口坐标，y 朝上）

    @Test("收起态：岛下方的大片透明区不吃点击")
    func collapsedLetsClicksThrough() {
        let view = makeView(state: .idle)
        let bounds = view.bounds

        // 画布中央（岛的正下方）—— 这里必须放行，否则屏幕顶部一大块全废。
        #expect(view.hitTest(CGPoint(x: bounds.midX, y: bounds.midY)) == nil)
        // 画布最下方。
        #expect(view.hitTest(CGPoint(x: bounds.midX, y: bounds.minY + 2)) == nil)
        // 与岛同高但在左右两侧之外。
        #expect(view.hitTest(CGPoint(x: bounds.minX + 2, y: bounds.maxY - 4)) == nil)
        #expect(view.hitTest(CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 4)) == nil)
    }

    @Test("展开态：画布左右两条留给内凹圆弧的边不吃点击")
    func expandedLetsEdgeClicksThrough() {
        let view = makeView(state: .expanded)
        let bounds = view.bounds
        #expect(view.hitTest(CGPoint(x: bounds.minX + 1, y: bounds.midY)) == nil)
        #expect(view.hitTest(CGPoint(x: bounds.maxX - 1, y: bounds.midY)) == nil)
    }

    @Test("岛尺寸为零时全部放行，不会误吞点击")
    func zeroSizedIslandSwallowsNothing() {
        let view = makeView(state: .idle)
        view.islandGeometry = { (.zero, IslandCornerRadii(bottom: 0, inverted: 0)) }
        #expect(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 1)) == nil)
        #expect(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil)
    }

    // MARK: - 轮廓本身

    @Test("岛的轮廓贴在画布顶部、水平居中")
    func islandPathIsAnchoredToCanvasTop() {
        let view = makeView(state: .running)
        let box = view.islandPath().boundingRect
        let bounds = view.bounds

        let topEdge = view.isFlipped ? box.minY : box.maxY
        let canvasTop = view.isFlipped ? bounds.minY : bounds.maxY
        #expect(abs(topEdge - canvasTop) < 0.5)
        #expect(abs(box.midX - bounds.midX) < 0.5)
        // 收起态只占画布顶部一条。
        #expect(box.height < bounds.height / 2)
    }

    @Test("轮廓内的点算命中：状态带中央在岛里，正下方远处不在")
    func pointsInsideIsland() {
        let view = makeView(state: .running)
        let path = view.islandPath()
        #expect(path.contains(viewPoint(view, fromTop: 6, x: view.bounds.midX)))
        #expect(!path.contains(viewPoint(view, fromTop: 200, x: view.bounds.midX)))
    }

    @Test("展开态铺满画布高度")
    func expandedFillsCanvasHeight() {
        let view = makeView(state: .expanded)
        let path = view.islandPath()
        #expect(path.contains(viewPoint(view, fromTop: 6, x: view.bounds.midX)))
        #expect(path.contains(viewPoint(view, fromTop: 200, x: view.bounds.midX)))
    }
}
