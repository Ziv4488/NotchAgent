//
//  ResizeHandles.swift
//  NotchAgent
//
//  展开态的拖拽边框：左右两条竖边改宽、底边改高、两个下角同时改。
//

import SwiftUI
import AppKit

struct ResizeHandles: View {
    let model: IslandModel
    /// 岛主体尺寸。手柄贴着它的边排。
    let islandSize: CGSize
    /// 上沿要空出多少不放手柄。
    ///
    /// **只需要空出内凹圆弧那一段**（`cornerRadii.inverted`，8pt）—— 那几行里岛的
    /// 边界在主体之外，手柄摆在主体边上是错位的。再往下岛的两侧就是笔直的了。
    ///
    /// 这里原来传的是整个菜单栏高度（32pt），于是竖边上面**空掉一大截没有手柄**，
    /// 扫过去毫无反应 —— 用户报的「位置不稳定，好暧昧」有一半是它。
    let topInset: CGFloat

    var body: some View {
        Color.clear
            .frame(width: islandSize.width, height: islandSize.height)
            // 这层底座只用来量出岛的尺寸好让手柄贴边排。**必须显式放行点击**——
            // Color.clear 在 SwiftUI 里是吃点击的，而这整块正压在输入框和 tab 条上面。
            .allowsHitTesting(false)
            // 左右两条竖边。上一版只有下角能拖，用户得摸到那个「微妙的位置」才有反应；
            // 谁调整窗口都是去抓侧边，这里必须有。
            .overlay(alignment: .leading) { verticalEdge(.leadingEdge) }
            .overlay(alignment: .trailing) { verticalEdge(.trailingEdge) }
            .overlay(alignment: .bottom) { bottomEdge }
            .overlay(alignment: .bottomLeading) { corner(isLeading: true) }
            .overlay(alignment: .bottomTrailing) { corner(isLeading: false) }
    }

    // MARK: - 三种手柄

    private func verticalEdge(_ kind: Kind) -> some View {
        handle(kind, width: true, height: false)
            .frame(width: Layout.edgeThickness)
            .padding(.top, topInset)
            .padding(.bottom, Layout.cornerSize.height)
    }

    private var bottomEdge: some View {
        handle(.bottomEdge, width: false, height: true)
            .frame(height: Layout.edgeThickness)
            .padding(.horizontal, Layout.cornerSize.width)
            .overlay {
                // 不画出来就等于没有这个功能。
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 28, height: 3)
                    .allowsHitTesting(false)
            }
    }

    /// 下角只有手势，不画任何东西。
    ///
    /// 这里试过画一对折角标记，但岛的下角是 12pt 圆角、贴着桌面，
    /// 一对直角线画上去读起来是「岛外面还套了个框」，比没有更糟。
    /// 可拖这件事交给底边那条横条提示，以及光标移上来时的形状变化。
    private func corner(isLeading: Bool) -> some View {
        handle(isLeading ? .bottomLeading : .bottomTrailing, width: true, height: true)
            .frame(width: Layout.cornerSize.width, height: Layout.cornerSize.height)
    }

    // MARK: - 拖拽

    /// 用**屏幕绝对坐标**算目标尺寸，不用 `DragGesture` 的 `translation`。
    ///
    /// 手柄是贴着岛边排的，岛一变宽手柄就跟着移动，于是手势的局部坐标系也在移动 ——
    /// 拿那个坐标系里的位移去加宽度，会形成「变宽→坐标系右移→位移变小→回缩」的
    /// 来回振荡，正是拖动时看到的闪烁。鼠标的屏幕坐标是绝对的，不受这一切影响。
    private func handle(_ kind: Kind,
                        width resizesWidth: Bool,
                        height resizesHeight: Bool) -> some View {
        DragTarget(onFrame: { model.resizeHandleFrames[kind] = $0 }) { phase in
            switch phase {
            case .began:
                let edges = model.expandedEdges
                let mouse = NSEvent.mouseLocation
                // 按下时鼠标和边缘之间差多少，全程保持这个差 —— 否则一按下岛就跳一下。
                grab = CGSize(
                    width: mouse.x - (edges.centerX + copysign(model.expandedWidth / 2,
                                                              mouse.x - edges.centerX)),
                    height: mouse.y - edges.bottomY)

            case .changed:
                guard let grab else { return }
                let edges = model.expandedEdges
                let mouse = NSEvent.mouseLocation
                let targetWidth = resizesWidth
                    ? abs((mouse.x - grab.width) - edges.centerX) * 2
                    : model.expandedWidth
                let targetHeight = resizesHeight
                    ? edges.topY - (mouse.y - grab.height) - model.metrics.expandedChromeHeight
                    : model.expandedContentHeight
                model.resizeExpanded(width: targetWidth, contentHeight: targetHeight)

            case .ended:
                grab = nil
            }
        }
    }

    @State private var grab: CGSize?

    /// 五块热区。**光标形状由 `NotchHostingView` 按这几块登记 cursor rect**，
    /// 位置则由各自的 `GeometryReader` 量出来报到 `model.resizeHandleFrames`。
    ///
    /// 为什么绕这一圈，见 `NotchHostingView.resetCursorRects()` 上面那段。
    enum Kind: Hashable, CaseIterable {
        case leadingEdge, trailingEdge, bottomEdge, bottomLeading, bottomTrailing

        var cursor: NSCursor {
            switch self {
            case .leadingEdge, .trailingEdge: return .resizeLeftRight
            case .bottomEdge: return .resizeUpDown
            case .bottomLeading: return Self.corner(isLeading: true)
            case .bottomTrailing: return Self.corner(isLeading: false)
            }
        }

        private static func corner(isLeading: Bool) -> NSCursor {
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: isLeading ? .bottomLeft : .bottomRight,
                                            directions: .all)
            }
            // 14 上没有公开的斜向 resize 光标，退回横向 —— 拖拽行为不受影响。
            return .resizeLeftRight
        }
    }

    enum Layout {
        /// 竖边 / 底边的可抓厚度。
        ///
        /// 6pt 太细，摸不着（用户报的「暧昧」）。**上限是 8** —— 竖边压在状态带的
        /// 最右边，而收起用的 ✕ 只留了 `StatusBand.Layout.closeTrailingInset` 那么点
        /// 右边距。再宽就压到 ✕ 上，§2.2b 那个「点了没反应」会重演。
        static let edgeThickness: CGFloat = 8
        static let cornerSize = CGSize(width: 30, height: 20)
    }
}

// MARK: - 手势与光标

private enum DragPhase { case began, changed, ended }

/// `DragGesture` 只用来知道「按下了 / 在动 / 松开了」，具体坐标一律自己从
/// `NSEvent.mouseLocation` 取。
private struct DragTarget: View {
    /// 把自己在画布里占的那块报上去 —— 光标形状归 `NotchHostingView` 登记。
    let onFrame: (CGRect) -> Void
    let onPhase: (DragPhase) -> Void

    @State private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !dragging {
                            dragging = true
                            onPhase(.began)
                        }
                        onPhase(.changed)
                    }
                    .onEnded { _ in
                        dragging = false
                        onPhase(.ended)
                    }
            )
            // 和 `model.menuFrame` 同一套路子：视图量完自己的位置报上去，
            // 由 `NotchHostingView` 拿去用。**不能在这儿塞 `NSViewRepresentable`** ——
            // 见 `NotchHostingView.resetCursorRects()` 上面那段。
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(IslandShell.canvas))
                    Color.clear
                        .onAppear { onFrame(frame) }
                        .onChange(of: frame) { _, new in onFrame(new) }
                        .onDisappear { onFrame(.zero) }
                }
            }
    }
}
