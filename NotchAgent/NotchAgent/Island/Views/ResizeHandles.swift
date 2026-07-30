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
    /// 上沿留给状态带的高度 —— 那一段两侧是内凹圆弧，放手柄会落到岛外面。
    let topInset: CGFloat

    var body: some View {
        Color.clear
            .frame(width: islandSize.width, height: islandSize.height)
            // 这层底座只用来量出岛的尺寸好让手柄贴边排。**必须显式放行点击**——
            // Color.clear 在 SwiftUI 里是吃点击的，而这整块正压在输入框和 tab 条上面。
            .allowsHitTesting(false)
            // 左右两条竖边。上一版只有下角能拖，用户得摸到那个「微妙的位置」才有反应；
            // 谁调整窗口都是去抓侧边，这里必须有。
            .overlay(alignment: .leading) { verticalEdge }
            .overlay(alignment: .trailing) { verticalEdge }
            .overlay(alignment: .bottom) { bottomEdge }
            .overlay(alignment: .bottomLeading) { corner(isLeading: true) }
            .overlay(alignment: .bottomTrailing) { corner(isLeading: false) }
    }

    // MARK: - 三种手柄

    private var verticalEdge: some View {
        handle(width: true, height: false, cursor: .resizeLeftRight)
            .frame(width: Layout.edgeThickness)
            .padding(.top, topInset)
            .padding(.bottom, Layout.cornerSize.height)
    }

    private var bottomEdge: some View {
        handle(width: false, height: true, cursor: .resizeUpDown)
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
        handle(width: true, height: true, cursor: Self.cornerCursor(isLeading: isLeading))
            .frame(width: Layout.cornerSize.width, height: Layout.cornerSize.height)
    }

    // MARK: - 拖拽

    /// 用**屏幕绝对坐标**算目标尺寸，不用 `DragGesture` 的 `translation`。
    ///
    /// 手柄是贴着岛边排的，岛一变宽手柄就跟着移动，于是手势的局部坐标系也在移动 ——
    /// 拿那个坐标系里的位移去加宽度，会形成「变宽→坐标系右移→位移变小→回缩」的
    /// 来回振荡，正是拖动时看到的闪烁。鼠标的屏幕坐标是绝对的，不受这一切影响。
    private func handle(width resizesWidth: Bool,
                        height resizesHeight: Bool,
                        cursor: NSCursor) -> some View {
        DragTarget(cursor: cursor) { phase in
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

    private static func cornerCursor(isLeading: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: isLeading ? .bottomLeft : .bottomRight,
                                        directions: .all)
        }
        // 14 上没有公开的斜向 resize 光标，退回横向 —— 拖拽行为不受影响。
        return .resizeLeftRight
    }

    private enum Layout {
        static let edgeThickness: CGFloat = 6
        static let cornerSize = CGSize(width: 30, height: 20)
    }
}

// MARK: - 手势与光标

private enum DragPhase { case began, changed, ended }

/// `DragGesture` 只用来知道「按下了 / 在动 / 松开了」，具体坐标一律自己从
/// `NSEvent.mouseLocation` 取。
private struct DragTarget: View {
    let cursor: NSCursor
    let onPhase: (DragPhase) -> Void

    @State private var dragging = false
    @State private var cursorPushed = false

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
            .onHover { inside in
                // push / pop 必须严格配对，多 pop 一次光标就会卡在 resize 形状上出不来。
                if inside, !cursorPushed {
                    cursor.push()
                    cursorPushed = true
                } else if !inside, cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }
}
