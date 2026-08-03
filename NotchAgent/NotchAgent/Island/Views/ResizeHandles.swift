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
        DragTarget(kind: kind, onFrame: { model.resizeHandleFrames[kind] = $0 }) { phase in
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
        // 挂在这一层、不挂进 `DragTarget` 里面：五块热区都从这儿过，一处都漏不掉，
        // 而且这样它会出现在 `body` 的类型里 —— 「有没有挂上」离线才验得了
        // （`ResizeCursorTests` 那条「五块热区都挂上了 pointerStyle」）。
        .resizePointer(kind)
    }

    @State private var grab: CGSize?

    /// 五块热区。
    ///
    /// **光标形状走 SwiftUI 的 `pointerStyle`（macOS 15+），不再走 AppKit 的
    /// cursor rect** —— 后者在实机上撑不住，第四版换的就是这条，理由见
    /// `usesLegacyCursorRects`。14 上没有这个 API，才退回 cursor rect，
    /// 位置由各自的 `GeometryReader` 量出来报到 `model.resizeHandleFrames`。
    enum Kind: Hashable, CaseIterable {
        case leadingEdge, trailingEdge, bottomEdge, bottomLeading, bottomTrailing

        /// 这块热区在岛的哪条边、哪个角上。
        ///
        /// **两条路的光标都从这里派生。** SwiftUI 和 AppKit 各有一个 resize 位置
        /// 枚举，各写一遍迟早写岔 —— 同一块热区在两条路上给出不同形状，
        /// 看起来就是「形状在抖」，正是用户说的「不清晰」。
        @available(macOS 15.0, *)
        var resizePosition: FrameResizePosition {
            switch self {
            case .leadingEdge: return .leading
            case .trailingEdge: return .trailing
            case .bottomEdge: return .bottom
            case .bottomLeading: return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }

        /// AppKit 那条路要的光标。**只有 macOS 14 会用到**（见 `usesLegacyCursorRects`）。
        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: Self.appKitPosition(resizePosition),
                                            directions: .all)
            }
            // 14 上没有公开的斜向 resize 光标，下角退回横向 —— 拖拽行为不受影响。
            switch self {
            case .bottomEdge: return .resizeUpDown
            default: return .resizeLeftRight
            }
        }

        @available(macOS 15.0, *)
        private static func appKitPosition(_ position: FrameResizePosition) -> NSCursor.FrameResizePosition {
            switch position {
            case .top: return .top
            case .bottom: return .bottom
            case .leading: return .left
            case .trailing: return .right
            case .topLeading: return .topLeft
            case .topTrailing: return .topRight
            case .bottomLeading: return .bottomLeft
            case .bottomTrailing: return .bottomRight
            @unknown default: return .bottom
            }
        }
    }

    /// 还要不要 AppKit 那条 cursor rect。**15 起一律不要，两套只留一套。**
    ///
    /// 前三版都栽在 cursor rect 上，第三版（画布统一登记）实机的结果是
    /// 「左右好了，下角和底边不清晰、来回几次就不显示」。离线量过：五块热区的
    /// 位置、登记、命中全都是对的，问题在登记**之后**——
    ///
    /// - cursor rect 只在**跨越边界那一下**触发。谁在指针已经停在框里的时候
    ///   把光标改掉（`SwiftTerm.TerminalView.cursorUpdate` 就无条件
    ///   `NSCursor.iBeam.set()`），就得出去再进来才回得来，正是「来回几次就没了」。
    /// - 登记在画布上，而终端在 z 序里压在画布**之上**。下角内探 30pt、
    ///   高 20pt，和终端（离岛边 15pt、离岛底 14pt）正好咬掉一块；
    ///   左右竖边只有 8pt 宽，够不着终端 —— 所以偏偏左右是好的。
    ///
    /// `pointerStyle` 两条都不沾：声明式、没有进出配对，按 SwiftUI 的 z 序算，
    /// 而拖拽层是加在最上面的 `.overlay`，压得住终端。
    ///
    /// 两套同时开着更糟（同一块地方两个来源抢，形状会抖），所以这里是二选一。
    static var usesLegacyCursorRects: Bool {
        if #available(macOS 15.0, *) { return false }
        return true
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

/// 指针移到这块热区上时该是什么形状。
///
/// `pointerStyle` 是 macOS 15 才有的。它和第一版那套 `.onHover` +
/// `NSCursor.push()/pop()` 的差别在于**它是声明式的**：不需要「进」和「出」
/// 严格配对，而手柄这棵子树按 `islandSize` 参数化、拖动时每帧重建，
/// 那对 push/pop 从来就配不上号。
///
/// **写成具名 `ViewModifier` 是为了能被测出来。** 直接写 `@ViewBuilder` +
/// `if #available` 的话，15 那一支会被擦成 `AnyView`，`body` 的类型里只剩
/// 一个 `_ConditionalContent<AnyView, DragTarget>` —— 看得出「挂了个条件」，
/// 看不出挂的是什么。具名之后类型里就是 `ModifiedContent<DragTarget, ResizePointer>`。
struct ResizePointer: ViewModifier {
    let kind: ResizeHandles.Kind

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.frameResize(position: kind.resizePosition, directions: .all))
        } else {
            content   // 14 上由 `NotchHostingView` 登记 cursor rect
        }
    }
}

extension View {
    func resizePointer(_ kind: ResizeHandles.Kind) -> some View {
        modifier(ResizePointer(kind: kind))
    }
}

/// `DragGesture` 只用来知道「按下了 / 在动 / 松开了」，具体坐标一律自己从
/// `NSEvent.mouseLocation` 取。
private struct DragTarget: View {
    let kind: ResizeHandles.Kind
    /// 把自己在画布里占的那块报上去 —— macOS 14 上光标归 `NotchHostingView` 登记。
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
