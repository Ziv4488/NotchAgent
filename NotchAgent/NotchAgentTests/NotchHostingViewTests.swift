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

    // MARK: - 挂在岛下面的选项浮层

    /// 浮层落在岛的轮廓之外，靠 `model.menuFrame` 单独放行。
    /// 那个矩形一旦和浮层的**真实**位置对不上，点上去就一点反应都没有 ——
    /// 用户报的「选项不能点击」。
    @Test("浮层报上来的位置就是它真实待的位置")
    func menuFrameMatchesWhereThePanelIs() async throws {
        let view = try await makeMenuView()
        let frame = view.rootView.model.menuFrame

        #expect(frame.isEmpty == false)
        // 浮层在画布里居中，就该压在画布中线上。原点若是量错了参照物
        // （比如取了岛那一层而不是整块画布），这里立刻差出半个画布。
        #expect(abs(frame.midX - view.bounds.midX) < 0.5)
        // 挂在岛下面，不该跑到岛上面去。
        #expect(frame.minY > 0)
    }

    /// 浮层是从岛上长下来的，不是另一张卡片：**贴着岛的底边**、和岛主体同宽。
    /// 中间只要有一道缝，缝里就是桌面，读起来立刻变成两样东西。
    @Test("浮层贴着岛的底边，和岛一样宽")
    func menuHangsFlushFromTheIsland() async throws {
        let view = try await makeMenuView()
        let model = view.rootView.model
        let frame = model.menuFrame

        #expect(abs(frame.minY - model.size.height) < 0.5)
        #expect(abs(frame.width - model.size.width) < 0.5)
    }

    @Test("点得到浮层")
    func menuPanelIsClickable() async throws {
        let view = try await makeMenuView()
        let frame = view.rootView.model.menuFrame
        try #require(frame.isEmpty == false)

        #expect(view.hitTest(hitPoint(view, at: CGPoint(x: frame.midX, y: frame.midY))) != nil)
    }

    /// 放行只针对浮层那一块。它左右两边仍是透明画布，得继续漏下去。
    @Test("浮层两侧照旧不吃点击")
    func besideTheMenuStillPassesThrough() async throws {
        let view = try await makeMenuView()
        let frame = view.rootView.model.menuFrame
        try #require(frame.isEmpty == false)

        #expect(view.hitTest(hitPoint(view, at: CGPoint(x: frame.minX - 20, y: frame.midY))) == nil)
        #expect(view.hitTest(hitPoint(view, at: CGPoint(x: frame.maxX + 20, y: frame.midY))) == nil)
    }
}

/// `hitTest` 的入参是父视图坐标系（y 朝上），量出来的浮层位置是画布自己的
/// 坐标系（`NSHostingView` 是 flipped 的，y 朝下）—— 中间这一下换算不能省。
@MainActor
private func hitPoint(_ view: NSView, at pointInView: CGPoint) -> CGPoint {
    view.convert(pointInView, to: view.superview)
}

/// 摆好一个「岛下面挂着选单」的画布。
///
/// **等的时候必须让出主线程**（`await`，不是 `RunLoop.run`）：
/// 同时在跑的 PTY 测试也要主线程派活，把它占死那边就超时了。
@MainActor
private func makeMenuView() async throws -> NotchHostingView {
    let model = IslandModel.previewModel(state: .notice)
    model.apply(TerminalMenu(question: "晚饭吃什么？",
                             options: [.init(number: 1, title: "麻辣香锅", detail: nil),
                                       .init(number: 2, title: "日式拉面", detail: nil)],
                             selected: 0),
                to: model.tabs[0].id)
    let view = NotchHostingView(rootView: IslandShell(model: model))
    view.frame = CGRect(origin: .zero, size: model.metrics.containerFrame.size)
    view.islandGeometry = { (model.size, model.cornerRadii) }
    // 浮层是量出来的，得真的走一遍渲染 —— 光 layout 不够，
    // 视图还必须挂在一个窗口上，`onAppear` 才会来。
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    // 量完才写回 model，等它写回来 —— 一到手就走，不空等。
    for _ in 0..<100 where model.menuFrame.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }
    return view
}
