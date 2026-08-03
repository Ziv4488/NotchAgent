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
    let cursor: NSCursor
    let onPhase: (DragPhase) -> Void

    @State private var dragging = false
    @Environment(\.installsCursorRects) private var installsCursorRects

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
            .overlay { if installsCursorRects { CursorRect(cursor: cursor) } }
    }
}

/// 光标形状交给 AppKit 自己那套 cursor rect，**不用 SwiftUI 的 `.onHover`**。
///
/// 原来是 `.onHover` 里 `NSCursor.push()` / `pop()`，用户报「出现箭头的时机和位置
/// 不稳定，好暧昧」（§8.2/8.3）。两个毛病：
///
/// 1. `push` / `pop` 动的是一个**全局栈**，要求严格配对。而这棵子树是按
///    `islandSize` 参数化的 —— 拖动时每一帧都在重建，`.onHover` 的进和出配不上号
///    （那个 `onDisappear` 里补的 `pop()` 就是为这个加的，但补不全）。
///    栈一歪，箭头要么不出现，要么离开了还卡着。
/// 2. `.onHover` 只有进、出两个时刻。中间任何一次 AppKit 重设光标都没人补回来
///    —— 比如从终端那块 I 型光标的 cursor rect 里出来时，AppKit 会把光标复位。
///
/// cursor rect 没有这两个问题：AppKit 每次鼠标移动都重新解析一遍，天然幂等，
/// 也不用配对；而且手柄那一块从此**有**一个明确的光标，不是靠一次性的 set 撑着。
///
/// **一个说法要更正**：先前写过「是 SwiftTerm 的 `addCursorRect(.iBeam)` 把箭头顶掉的」。
/// 量了一下不成立 —— 终端离岛边还有 15pt（卡片内缩 7 + 终端自己的 padding 8），
/// 而手柄只占最外面 8pt，两者根本不重叠。真正站得住的是上面那两条。
///
// 不是 private：`ResizeCursorTests` 要挂起来查它登记了什么。
struct CursorRect: NSViewRepresentable {

    let cursor: NSCursor

    func makeNSView(context: Context) -> TrackingView { TrackingView(cursor: cursor) }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class TrackingView: NSView {

        var cursor: NSCursor
        /// 上一次登记的矩形与光标。只为测试可见 —— `addCursorRect` 登记进去之后
        /// AppKit 不给任何查询的口子，不留一份就没法断言「到底登记了什么」。
        private(set) var registered: (rect: NSRect, cursor: NSCursor)?

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
            registered = (bounds, cursor)
        }

        /// **一个点击都不许吃。** 这层是盖在岛上的，§2.2b 踩过一次：
        /// 拖拽层没放行点击，把 tab 芯片和 ✕ 全挡掉了，表现和「光标没激活」难以区分。
        /// 手势仍然在 SwiftUI 那一层，这里只负责光标形状。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // 视图一动，之前登记的矩形就过期了 —— 拖拽时手柄是一直在动的。
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
    }
}

// MARK: - 让像素测试看得见底下的东西

private struct InstallsCursorRectsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 要不要往视图树里塞那层登记光标用的 AppKit 视图。生产里永远是 true。
    ///
    /// **`IslandPixelTests` 把它关掉。** `ImageRenderer` 画不了 AppKit 支撑的内容，
    /// 会拿一块不透明的黄块顶上去（实测就是 `1.00/0.80/0.00`，`TextField` 也一样），
    /// 把它底下真正要量的东西整块盖住 —— 卡片的下角就在拖拽手柄底下。
    /// 关掉这一层，量到的才是 SwiftUI 自己画的那些。
    var installsCursorRects: Bool {
        get { self[InstallsCursorRectsKey.self] }
        set { self[InstallsCursorRectsKey.self] = newValue }
    }
}

