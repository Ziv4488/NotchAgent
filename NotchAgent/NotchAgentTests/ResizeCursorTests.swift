//
//  ResizeCursorTests.swift
//  NotchAgentTests
//
//  拖拽热区：位置报上来了没有、光标接对了没有、会不会顺手把点击也吃了。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// **起因：用户 2026-08-03 报「出现箭头的时机和位置不稳定，好暧昧」（§8.2/8.3）。**
///
/// 到 08-04 为止改了三版，前两版都是我判断错了，记在这儿免得再走一遍：
///
/// | 版本 | 做法 | 结果 |
/// |---|---|---|
/// | 原版 | `.onHover` + `NSCursor.push()` / `pop()` | 箭头时有时无 —— `push`/`pop` 是全局栈、要求严格配对，而手柄这棵子树按 `islandSize` 参数化，拖动时每帧重建，进和出配不上号 |
/// | 第二版 | 手柄里塞一个 `NSViewRepresentable` 自己 `addCursorRect` | **一个箭头都不出现**。那层为了不吞点击必须 `hitTest` 返回 nil，而窗口找「该用哪个光标」要先命中到视图 —— 命不中的视图，登记的矩形没人问 |
/// | 现在 | 手柄用 `GeometryReader` 把自己的位置报到 `model.resizeHandleFrames`，由 `NotchHostingView`（本来就可命中）登记 cursor rect | 待实测 |
///
/// 还更正过一个诊断：先前说是 SwiftTerm 的 `addCursorRect(.iBeam)` 把箭头顶掉的。
/// 量了不成立 —— 终端离岛边还有 15pt（卡片内缩 7 + 它自己的 padding 8），
/// 而热区最宽的下角也只探进来 30pt、只在最底下 20pt，两者不重叠。
///
/// **「手挪过去到底出不出箭头」离线测不了**（要真的动鼠标，而这台机器上有人在用）。
/// 这里钉的是它前面每一步：位置报上来了没有、报的是不是真实布局、
/// 光标接对了没有、AppKit 自己会不会来问、以及会不会吞掉点击。
@Suite("拖拽热区与光标")
@MainActor
struct ResizeCursorTests {

    /// 盖住 `addCursorRect` 抄一份 —— 这样断言的是**窗口派下来的活**，
    /// 不是我们自己调了一遍。
    final class RecordingHostingView: NotchHostingView {
        var added: [(rect: NSRect, cursor: NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
            added.append((rect, object))
            super.addCursorRect(rect, cursor: object)
        }
    }

    private func mountIsland() async -> (NSWindow, RecordingHostingView, IslandModel) {
        let model = IslandModel.previewModel(state: .expanded)
        let size = CGSize(width: model.size.width + 200, height: model.size.height + 100)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = RecordingHostingView(rootView: IslandShell(model: model))
        hosting.islandGeometry = { (model.size, model.cornerRadii) }
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()

        // 让 `GeometryReader` 的 onAppear 走完 —— 位置是那时候才报上来的。
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        return (window, hosting, model)
    }

    /// 五块热区都得把自己的位置报上来。少报一块，那条边上就没有光标。
    @Test("五块热区都把位置报上来了")
    func everyHandleReportsItsFrame() async throws {
        let (window, _, model) = await mountIsland()
        defer { window.orderOut(nil) }

        for kind in ResizeHandles.Kind.allCases {
            let frame = try #require(model.resizeHandleFrames[kind], "\(kind) 没报位置")
            #expect(frame.width > 0 && frame.height > 0, "\(kind) 报了个空矩形：\(frame)")
        }
    }

    /// 报上来的必须是**真实布局**里的位置，不是谁在别处重算的一份。
    ///
    /// 竖边贴着岛的左右两沿、和岛一样高（减去上沿让位和下角那一段）；
    /// 底边贴着岛的下沿。位置对不上就是光标出现在错的地方 —— 用户报的「位置暧昧」。
    @Test("报上来的位置贴着岛的边")
    func reportedFramesHugTheIslandEdges() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        // 岛贴着画布顶边、水平居中。
        let bodyLeft = (hosting.bounds.width - model.size.width) / 2
        let bodyRight = bodyLeft + model.size.width
        let bodyBottom = model.size.height

        let leading = try #require(model.resizeHandleFrames[.leadingEdge])
        #expect(abs(leading.minX - bodyLeft) <= 1, "左竖边在 \(leading.minX)，岛的左沿在 \(bodyLeft)")
        #expect(abs(leading.width - ResizeHandles.Layout.edgeThickness) <= 1)
        // 上沿只让开内凹圆弧那一段 —— 让开整条状态带的话这里会是 32。
        #expect(abs(leading.minY - model.cornerRadii.inverted) <= 1,
                "左竖边从 y=\(leading.minY) 起，该是内凹半径 \(model.cornerRadii.inverted)")

        let trailing = try #require(model.resizeHandleFrames[.trailingEdge])
        #expect(abs(trailing.maxX - bodyRight) <= 1, "右竖边在 \(trailing.maxX)，岛的右沿在 \(bodyRight)")

        let bottom = try #require(model.resizeHandleFrames[.bottomEdge])
        #expect(abs(bottom.maxY - bodyBottom) <= 1, "底边在 \(bottom.maxY)，岛的下沿在 \(bodyBottom)")
    }

    /// 每块热区要的箭头不一样，别接错线。
    @Test("光标接对了线")
    func eachHandleAsksForTheRightCursor() {
        #expect(ResizeHandles.Kind.leadingEdge.cursor === NSCursor.resizeLeftRight)
        #expect(ResizeHandles.Kind.trailingEdge.cursor === NSCursor.resizeLeftRight)
        #expect(ResizeHandles.Kind.bottomEdge.cursor === NSCursor.resizeUpDown)
        // 下角在 15+ 上是斜向的，14 上退回横向 —— 两种都不该是默认箭头。
        #expect(ResizeHandles.Kind.bottomLeading.cursor !== NSCursor.arrow)
        #expect(ResizeHandles.Kind.bottomTrailing.cursor !== NSCursor.arrow)
        #expect(ResizeHandles.Kind.bottomLeading.cursor !== ResizeHandles.Kind.bottomEdge.cursor)
    }

    /// **AppKit 自己会来问**，而且问到的是五块热区。
    ///
    /// 上一版栽在这一步上：测试自己调了一遍 `resetCursorRects()` 就说「登记好了」，
    /// 而实机上 AppKit 压根没来问过那个视图。这里不自己调 —— 挂进真窗口、
    /// 让布局跑完，然后看窗口有没有把这活派下来。
    @Test("AppKit 会来问这块画布要 cursor rect")
    func appKitAsksTheHostingViewForCursorRects() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        hosting.added.removeAll()
        window.resetCursorRects()   // 这一下是窗口派活，不是我们自己登记
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(hosting.added.count >= ResizeHandles.Kind.allCases.count,
                "只登记了 \(hosting.added.count) 块，五块热区没都登记上")
        // 登记的矩形要和报上来的位置对得上，光标也要是那块热区要的那个。
        for kind in ResizeHandles.Kind.allCases {
            let frame = try #require(model.resizeHandleFrames[kind])
            let match = hosting.added.first { $0.rect.equalTo(frame) }
            let registered = try #require(match, "\(kind) 那块没被登记：\(frame)")
            #expect(registered.cursor === kind.cursor, "\(kind) 登记的光标不对")
        }
    }

    /// 热区加宽到 8pt 是为了好抓，但**不能宽到压住收起用的 ✕**。
    /// 竖边就贴在状态带最右边那条线上，✕ 只留了那么点右边距。
    @Test("竖边的热区不会压到 ✕ 上")
    func theEdgeHandleLeavesTheCloseButtonAlone() {
        let thickness = ResizeHandles.Layout.edgeThickness
        let closeInset = StatusBand.Layout.closeTrailingInset
        #expect(thickness <= closeInset,
                "手柄 \(thickness)pt 宽，而 ✕ 只离右沿 \(closeInset)pt")
        // 太细就是「摸不着」，那正是这轮要修的。
        #expect(thickness >= 8)
    }
}
