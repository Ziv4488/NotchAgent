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
/// | 第三版 | 手柄把位置报到 `model.resizeHandleFrames`，由 `NotchHostingView`（本来就可命中）登记 cursor rect | **左右好了，下角和底边不清晰、来回几次就不显示** |
/// | 第四版 | 丢掉 cursor rect，改用 SwiftUI 的 `pointerStyle`（macOS 15+） | **进 → 有、出 → 还有、再进 → 没了**：只在岛是 key 的时候才生效 |
/// | 现在 | 再加一条：`.activeAlways` 的跟踪区，非 key 时由 `NotchHostingView` 在进出事件里自己设 | 待实测 |
///
/// **前四版全栽在同一件事上，第五版才量出来**：AppKit 的光标机制
/// （cursor rect、`.cursorUpdate` 跟踪区、`pointerStyle`）**默认只在 key window
/// 里生效**，而岛是 `.nonactivatingPanel`。真的把指针挪过去读
/// `NSCursor.currentSystem`（`CursorShapeTests`），三格是这样的：
/// active+key ✓、active+非 key ✗（第四版）、inactive ✗（**系统限制，改不了**）。
///
/// 第三版为什么是「左右行、下面不行」，离线量出来的（探针：位置、登记、命中全对）：
///
/// - cursor rect **只在跨越边界那一下触发**。`SwiftTerm.TerminalView.cursorUpdate`
///   无条件 `NSCursor.iBeam.set()`，光标一旦在框内被它改掉，就得出去再进来
///   才回得来 —— 用户说的「来回几次就会不显示」。
/// - 矩形登记在画布上，而终端在 z 序里压在画布**之上**。下角内探 30pt、高 20pt，
///   和终端（离岛边 15pt、离岛底 14pt）咬掉一块；左右竖边只有 8pt 宽，
///   够不着终端 —— 所以偏偏左右是好的。
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
    /// 三条边都**跨在岛的边线上**：里面 4pt、外面 4pt（2026-08-04 改的，之前
    /// 8pt 全在岛里面 —— 得先把指针挪进岛才拖得动，和拖系统窗口的手感不一样）。
    /// 位置对不上就是光标出现在错的地方 —— 用户报过的「位置暧昧」。
    ///
    /// 内外那两个数**写死在断言里**，不引用 `Layout.innerReach` / `.outerReach`：
    /// 引用的话等号两边一起动，把热区改回全在里面这条照样绿。
    @Test("报上来的位置跨在岛的边线上：里 4pt、外 4pt")
    func reportedFramesStraddleTheIslandEdges() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        // 岛贴着画布顶边、水平居中。
        let bodyLeft = (hosting.bounds.width - model.size.width) / 2
        let bodyRight = bodyLeft + model.size.width
        let bodyBottom = model.size.height

        let leading = try #require(model.resizeHandleFrames[.leadingEdge])
        #expect(abs(leading.minX - (bodyLeft - 4)) <= 1,
                "左竖边外沿在 \(leading.minX)，该在岛左沿 \(bodyLeft) 外 4pt")
        #expect(abs(leading.maxX - (bodyLeft + 4)) <= 1,
                "左竖边内沿在 \(leading.maxX)，该在岛左沿 \(bodyLeft) 内 4pt")
        // 上沿只让开内凹圆弧那一段 —— 让开整条状态带的话这里会是 32。
        #expect(abs(leading.minY - model.cornerRadii.inverted) <= 1,
                "左竖边从 y=\(leading.minY) 起，该是内凹半径 \(model.cornerRadii.inverted)")

        let trailing = try #require(model.resizeHandleFrames[.trailingEdge])
        #expect(abs(trailing.maxX - (bodyRight + 4)) <= 1,
                "右竖边外沿在 \(trailing.maxX)，该在岛右沿 \(bodyRight) 外 4pt")
        #expect(abs(trailing.minX - (bodyRight - 4)) <= 1, "右竖边内沿在 \(trailing.minX)")

        let bottom = try #require(model.resizeHandleFrames[.bottomEdge])
        #expect(abs(bottom.maxY - (bodyBottom + 4)) <= 1,
                "底边外沿在 \(bottom.maxY)，该在岛下沿 \(bodyBottom) 外 4pt")
        #expect(abs(bottom.minY - (bodyBottom - 4)) <= 1, "底边内沿在 \(bottom.minY)")

        // 两个下角也得跟着探出去，不然角上有一小块够不着。
        let corner = try #require(model.resizeHandleFrames[.bottomTrailing])
        #expect(abs(corner.maxX - (bodyRight + 4)) <= 1, "右下角外沿在 \(corner.maxX)")
        #expect(abs(corner.maxY - (bodyBottom + 4)) <= 1, "右下角下沿在 \(corner.maxY)")
    }

    /// **岛外面那 4pt 得由命中测试收下。**
    ///
    /// 透明画布一律不吃点击（§2.2b 的旧账），热区跨到边线外面之后，外面那半圈
    /// 要是照旧穿透，就成了「光标已经变成缩放箭头，按下去却落到底下的窗口上」。
    /// 再往外一点则必须照旧穿透 —— 收回来的只能是热区那几 pt。
    @Test("岛外那 4pt 归岛收，再往外照旧穿透")
    func theOuterReachIsNotSwallowedByTheCanvas() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        let bodyLeft = (hosting.bounds.width - model.size.width) / 2
        let row = model.size.height / 2

        #expect(hosting.accepts(CGPoint(x: bodyLeft - 2, y: row)),
                "岛左沿外 2pt 落在热区里，却没被收下")
        #expect(hosting.accepts(CGPoint(x: bodyLeft + 2, y: row)), "岛左沿内 2pt 本来就在岛里")
        #expect(!hosting.accepts(CGPoint(x: bodyLeft - 9, y: row)),
                "岛左沿外 9pt 已经出了热区，不该再被岛吃掉")
        // 岛的正下方远处照旧穿透 —— 这块是那片透明画布。
        #expect(!hosting.accepts(CGPoint(x: hosting.bounds.midX,
                                         y: model.size.height + 60)))
    }

    /// 每块热区在岛的哪条边上 —— **两条路的光标都从这一个映射派生**，
    /// 所以接错线在这里就能看出来。各写一遍的话，同一块热区在 SwiftUI 那条路
    /// 和 AppKit 那条路上会给出不同形状，看起来就是形状在抖。
    @available(macOS 15.0, *)
    @Test("热区认得自己在哪条边上")
    func eachHandleKnowsItsEdge() {
        #expect(ResizeHandles.Kind.leadingEdge.resizePosition == .leading)
        #expect(ResizeHandles.Kind.trailingEdge.resizePosition == .trailing)
        #expect(ResizeHandles.Kind.bottomEdge.resizePosition == .bottom)
        #expect(ResizeHandles.Kind.bottomLeading.resizePosition == .bottomLeading)
        #expect(ResizeHandles.Kind.bottomTrailing.resizePosition == .bottomTrailing)
    }

    /// **五块热区都得挂上 `ResizePointer`，一块都不能漏。**
    ///
    /// 挂没挂上是这轮修法的全部内容，可它偏偏是最难验的一步 —— 「指针移过去变成什么」
    /// 要真的动鼠标。退而求其次：`body` 的类型里数一数。
    /// `ModifiedContent<DragTarget, ResizePointer>` 出现五次，才是五块都挂上了。
    ///
    /// 这也是 `ResizePointer` 写成具名 `ViewModifier` 的原因：直接写
    /// `@ViewBuilder` + `if #available`，15 那一支会被擦成 `AnyView`，
    /// 类型里只剩个 `_ConditionalContent<AnyView, DragTarget>`，数不出是什么。
    ///
    /// 这条钉的是「挂上了」。**「挂上之后系统真的会照着画」离线证不了**，
    /// 归手测 §8.2/8.3。
    @Test("五块热区都挂上了 pointerStyle")
    func everyHandleCarriesTheResizePointer() {
        let model = IslandModel.previewModel(state: .expanded)
        let handles = ResizeHandles(model: model, islandSize: model.size, topInset: 8)
        let described = String(describing: type(of: handles.body))

        let mounted = described.components(separatedBy: "ModifiedContent<DragTarget, ResizePointer>").count - 1
        #expect(mounted == ResizeHandles.Kind.allCases.count,
                "只有 \(mounted) 块热区挂上了指针样式，该是 \(ResizeHandles.Kind.allCases.count) 块")
    }

    /// 14 那条路（cursor rect）要的箭头。五块各不相同，且都不是默认箭头。
    @Test("光标接对了线")
    func eachHandleAsksForTheRightCursor() {
        for kind in ResizeHandles.Kind.allCases {
            #expect(kind.cursor !== NSCursor.arrow, "\(kind) 给的是默认箭头")
        }
        #expect(ResizeHandles.Kind.bottomEdge.cursor !== ResizeHandles.Kind.leadingEdge.cursor,
                "底边和竖边不该是同一个光标")
        #expect(ResizeHandles.Kind.bottomLeading.cursor !== ResizeHandles.Kind.bottomEdge.cursor)
    }

    /// **两套机制不许同时开着。**
    ///
    /// 15 起光标归 SwiftUI 的 `pointerStyle`。这时画布**一块 cursor rect 也不该登记** ——
    /// 同一块地方两个来源抢，形状会抖，那正是用户报的「不清晰」。
    /// 14 上反过来：没有 `pointerStyle`，五块热区必须全登记上。
    ///
    /// 这里不自己调 `resetCursorRects()`，挂进真窗口让窗口来派活 ——
    /// 第二版就栽在「测试自己调了一遍就当作数」上，而实机上 AppKit 压根没问过。
    @Test("光标只走一条路")
    func onlyOneCursorMechanismIsLive() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        hosting.added.removeAll()
        window.resetCursorRects()   // 这一下是窗口派活，不是我们自己登记
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard ResizeHandles.usesLegacyCursorRects else {
            #expect(hosting.added.isEmpty,
                    "pointerStyle 那条路开着，还登记了 \(hosting.added.count) 块 cursor rect")
            return
        }
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

    /// 非 key 那条路的跟踪区，五块热区一块不少。
    ///
    /// 岛多数时候不是 key window，那时 `pointerStyle` 不生效，全靠这几块跟踪区
    /// 的进出事件把光标设上（见 `NotchHostingView.updateTrackingAreas`）。
    @Test("五块热区都装了跟踪区")
    func everyHandleGetsATrackingArea() async throws {
        let (window, hosting, model) = await mountIsland()
        defer { window.orderOut(nil) }

        #expect(hosting.handleAreas.count == ResizeHandles.Kind.allCases.count,
                "只装了 \(hosting.handleAreas.count) 块跟踪区")
        for kind in ResizeHandles.Kind.allCases {
            let frame = try #require(model.resizeHandleFrames[kind])
            #expect(hosting.handleAreas.contains { $0.rect.equalTo(frame) }, "\(kind) 那块没装上")
        }
    }

    /// **热区没挪的时候不许重装跟踪区。**
    ///
    /// 每次 `layout` 都重装会出一个很隐蔽的毛病：「指针正停在框里、把框撤掉」
    /// **不产生 `mouseExited`**，再装上时指针已经在别处，也不会有 `mouseEntered`
    /// —— 于是光标停在上一个形状上再也不还原。实测过：指针从底边挪进内容区，
    /// 进出事件一次都不来，调整光标一路挂着出了岛，正是用户报的
    /// 「移出岛外的时候也有箭头」。
    @Test("热区没挪的时候不重装跟踪区")
    func trackingAreasSurviveALayoutPass() async throws {
        let (window, hosting, _) = await mountIsland()
        defer { window.orderOut(nil) }

        let before = hosting.handleAreas.map(ObjectIdentifier.init)
        #expect(before.isEmpty == false)
        hosting.layout()
        hosting.updateTrackingAreas()
        #expect(hosting.handleAreas.map(ObjectIdentifier.init) == before,
                "热区一点没挪，跟踪区却被重装了 —— 这一下会吃掉 mouseExited")
    }

    /// 这台机器上到底走的是哪条路 —— 记在测试报告里，免得看到上面那条
    /// 「一块也没登记」还以为是坏了。
    @Test("15 起不走 cursor rect")
    func modernSystemsSkipCursorRects() {
        if #available(macOS 15.0, *) {
            #expect(ResizeHandles.usesLegacyCursorRects == false)
        } else {
            #expect(ResizeHandles.usesLegacyCursorRects)
        }
    }

    /// 热区加宽到 8pt 是为了好抓，但**不能宽到压住收起用的 ✕**。
    /// 竖边就贴在状态带最右边那条线上，✕ 只留了那么点右边距。
    ///
    /// 会不会压到 ✕，看的是热区往岛**里**伸多少 —— 外面那半截在岛外面，
    /// 上面不可能有按钮。2026-08-04 改成跨边之后里面那半从 8pt 减到 4pt，
    /// 这条比以前更宽松，但仍然得钉着：两个数都还会有人去动。
    @Test("竖边的热区不会压到 ✕ 上")
    func theEdgeHandleLeavesTheCloseButtonAlone() {
        let inner = ResizeHandles.Layout.innerReach
        let closeInset = StatusBand.Layout.closeTrailingInset
        #expect(inner <= closeInset,
                "手柄往岛里伸 \(inner)pt，而 ✕ 只离右沿 \(closeInset)pt")
        // 太细就是「摸不着」，那正是这轮要修的 —— 总厚度算里外两半。
        #expect(ResizeHandles.Layout.edgeThickness >= 8)
    }
}
