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

    /// 岛一变形热区就挪位置，登记过的矩形当场过期。
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
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
