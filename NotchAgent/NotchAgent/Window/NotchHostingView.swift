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

final class NotchHostingView: NSHostingView<IslandShell> {

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 收到的是父视图坐标系里的点。
        let local = convert(point, from: superview)
        // 岛的轮廓，外加挂在它下面的选项浮层 —— 那块在轮廓之外，
        // 不单独放行的话点上去没有任何反应（透明区一律不收事件）。
        guard islandPath().contains(local) || menuRect().contains(local) else { return nil }
        return super.hitTest(point)
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
