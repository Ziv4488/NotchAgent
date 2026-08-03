//
//  NotchHostingView.swift
//  NotchAgent
//
//  岛的画布固定是最大态尺寸（这样 SwiftUI 才能顺滑地插值变形），
//  但那意味着一块 576×430 的透明窗口压在屏幕顶部。
//  必须把命中测试收回到岛的真实轮廓里，否则透明区会把点击全吞掉。
//

import AppKit
import SwiftUI

// 不是 `final`：`ResizeCursorTests` 要继承它、盖住 `addCursorRect` 抄一份参数。
// AppKit 登记进去之后不给任何查询的口子，不抄就没法断言「窗口到底派了什么活下来」
// —— 而上一版光标改坏，栽的正是「测试自己调了一遍就当作数」。
class NotchHostingView: NSHostingView<IslandShell> {

    /// 岛此刻的尺寸与圆角，由窗口层注入。
    var islandGeometry: () -> (size: CGSize, radii: IslandCornerRadii) = {
        (.zero, IslandCornerRadii(bottom: 0, inverted: 0))
    }

    required init(rootView: IslandShell) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 岛不是「先点亮自己、再干活」的窗口。app 在后台时点岛的第一下就该算数，
    /// 而不是只用来把焦点拿回来（键盘那一半在 `NotchWindow.activateForClick`）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 收到的是父视图坐标系里的点。
        let local = convert(point, from: superview)
        // 岛的轮廓，外加挂在它下面的选项浮层 —— 那块在轮廓之外，
        // 不单独放行的话点上去没有任何反应（透明区一律不收事件）。
        guard islandPath().contains(local) || menuRect().contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// 拖拽热区的光标形状 —— **只在 macOS 14 上走这里**。
    ///
    /// 15 起交给 SwiftUI 的 `pointerStyle`（见 `ResizeHandles.usesLegacyCursorRects`
    /// 上面那段：cursor rect 只在跨边界那一下触发，被终端的 `cursorUpdate` 改掉
    /// 就回不来；而且画布在 z 序上压在终端下面，下角正好被咬掉一块）。
    /// 两套同时开着会在同一块地方互相抢，所以是二选一。
    ///
    /// 14 上仍然**登记在这儿、不登记在手柄自己身上**：试过在手柄那层塞一个
    /// `NSViewRepresentable` 去 `addCursorRect`，实机一个箭头都不出现 ——
    /// 那层为了不吞点击（§2.2b 的旧账）必须 `hitTest` 返回 nil，
    /// 而窗口找「该用哪个光标」要先命中到视图。这块画布本来就是可命中的。
    override func resetCursorRects() {
        super.resetCursorRects()
        guard ResizeHandles.usesLegacyCursorRects else { return }
        for (kind, frame) in rootView.model.resizeHandleFrames where !frame.isEmpty {
            addCursorRect(frame, cursor: kind.cursor)
        }
    }

    // MARK: - 非 key 状态下的光标

    /// 已经装上去的热区。**只有真的挪了才重装。**
    ///
    /// 每次 `layout` 都重装是不行的：「指针正停在框里、把框撤掉」**不会产生
    /// `mouseExited`**，再装上时指针已经在别处，也不会有 `mouseEntered` ——
    /// 于是光标停在上一个形状上再也不还原。实测：指针从底边挪进内容区，
    /// 进出事件一次都不来，调整光标一路挂着出了岛（用户报的
    /// 「移出岛外的时候也有箭头」）。
    private var installedHandleFrames: [ResizeHandles.Kind: CGRect] = [:]
    /// 内部可见：`ResizeCursorTests` 要数「装了几块」「有没有被反复重装」。
    private(set) var handleAreas: [NSTrackingArea] = []
    /// 现在挂着的是不是我们设的那个 —— 只收自己放出去的，别去动终端的 I 型光标。
    private var showingResizeCursor = false

    /// 用 `.activeAlways` 的跟踪区，**因为岛多数时候不是 key window**。
    ///
    /// 这是前四版都栽了的根因。AppKit 的光标区（cursor rect、`.cursorUpdate`
    /// 跟踪区、SwiftUI 的 `pointerStyle`）默认只在 **key window** 里生效，
    /// 而岛是 `.nonactivatingPanel`，`canBecomeKey` 只在展开态为真、
    /// 还得用户点过它才成立。实测（把指针挪到八个位置读 `NSCursor.currentSystem`）：
    ///
    /// - 非 key：八个点**全是普通箭头**，热区上也一样；`cursorUpdate` 一次都不来。
    /// - key：八个点全对。
    ///
    /// 而 `.mouseEnteredAndExited` + `.activeAlways` 在非 key 下**照常送达**，
    /// 所以光标改在进出事件里自己设。
    ///
    /// **`.activeAlways` 这个标志测不出来**，说在前面：把它去掉，
    /// `CursorShapeTests` 照样绿 —— 两个用例里 app 都是 active 的，
    /// 而「app 不 active」那一格系统根本不给改光标（量过），所以在可测的范围内
    /// 它不承重。留着是因为它更贴意图，且哪天系统放开了就能用上。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let frames = rootView.model.resizeHandleFrames.filter { !$0.value.isEmpty }
        guard frames != installedHandleFrames else { return }

        for area in handleAreas { removeTrackingArea(area) }
        handleAreas = frames.values.map {
            NSTrackingArea(rect: $0, options: [.activeAlways, .mouseEnteredAndExited],
                           owner: self, userInfo: nil)
        }
        for area in handleAreas { addTrackingArea(area) }
        installedHandleFrames = frames
        // 刚换过一批框，指针此刻在哪儿得重新算一次 —— 重装本身不产生进出事件。
        refreshCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshCursor()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshCursor()
    }

    /// 按指针**此刻**的位置定形状。
    ///
    /// 不用事件里带的坐标：`mouseExited` 给的是「离开时那一点」，常常还压在框的边上，
    /// 拿它判断会得出「还在框里」，于是永远不还原。
    private func refreshCursor() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if let kind = rootView.model.resizeHandleFrames.first(where: { $0.value.contains(point) })?.key {
            kind.cursor.set()
            showingResizeCursor = true
        } else if showingResizeCursor {
            NSCursor.arrow.set()
            showingResizeCursor = false
        }
    }

    /// 岛一变形热区就挪位置，登记过的矩形当场过期。
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    /// 选项浮层占的那块。没有浮层时是空矩形，`contains` 恒为假。
    private func menuRect() -> CGRect {
        let frame = rootView.model.menuFrame
        return frame.isEmpty ? .null : frame
    }

    /// 岛的轮廓，转换到本视图坐标系。
    ///
    /// `NSHostingView` 是 flipped 的（y 朝下），和 SwiftUI `Path` 一致，正常情况下
    /// 只要平移。但 `isFlipped` 不是本类的承诺，所以两种约定都处理，别赌。
    func islandPath() -> Path {
        let (size, radii) = islandGeometry()
        guard size.width > 0, size.height > 0 else { return Path() }

        let canvasWidth = size.width + radii.inverted * 2
        // 岛贴在画布顶部、水平居中。
        let originX = bounds.midX - canvasWidth / 2

        let shape = NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: canvasWidth, height: size.height))

        guard isFlipped else {
            // y 朝上：先竖直翻转，再平移到画布顶部。
            return path
                .applying(CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -size.height))
                .applying(CGAffineTransform(translationX: originX, y: bounds.maxY - size.height))
        }
        return path.applying(CGAffineTransform(translationX: originX, y: bounds.minY))
    }
}
