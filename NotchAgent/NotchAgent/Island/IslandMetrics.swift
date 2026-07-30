//
//  IslandMetrics.swift
//  NotchAgent
//
//  几何 + 状态 → 具体的尺寸与圆角（spec 3.1 那张表）。
//

import CoreGraphics

/// 可调的排版常量。集中在这里，1.5 调视觉时只动这一处。
struct IslandConstants: Equatable, Sendable {
    /// idle 态在刘海左右各多出的宽度。
    /// 比 running 窄一点，让「闲着」和「在跑」一眼能分开，但仍放得下一行信息。
    var idleSideBleed: CGFloat = 90
    /// running 态在刘海左右各多出的宽度。
    var runningSideBleed: CGFloat = 110
    /// expanded 态的默认宽度（可拖拽调整并记住）。约等于 80 列终端。
    var expandedWidth: CGFloat = 560
    /// tab 条高度。
    var tabStripHeight: CGFloat = 34
    /// expanded 态内容区高度。
    var contentHeight: CGFloat = 320
    /// expanded 态输入框（含外边距）高度。
    var inputBarHeight: CGFloat = 44
    /// 无刘海屏的宽度基准，替代刘海宽度（spec 3.4）。
    var fallbackNotchWidth: CGFloat = 200

    /// 底部圆角半径。
    var bottomCornerRadius: CGFloat = 12
    /// 上沿两侧内凹拐角半径。无刘海时强制为 0。
    var invertedCornerRadius: CGFloat = 8

    static let `default` = IslandConstants()
}

/// 岛的两种圆角。
struct IslandCornerRadii: Equatable, Sendable {
    var bottom: CGFloat
    var inverted: CGFloat
}

struct IslandMetrics {
    let geometry: ScreenGeometryProviding
    var constants: IslandConstants

    /// expanded 宽度是用户可调的，覆盖 constants 里的默认值。
    var expandedWidth: CGFloat

    init(geometry: ScreenGeometryProviding,
         constants: IslandConstants = .default,
         expandedWidth: CGFloat? = nil) {
        self.geometry = geometry
        self.constants = constants
        self.expandedWidth = expandedWidth ?? constants.expandedWidth
    }

    /// 宽度基准：有刘海取刘海实际宽度，无刘海取固定值。
    var baseWidth: CGFloat {
        geometry.notchWidth ?? constants.fallbackNotchWidth
    }

    // MARK: - 尺寸

    /// `tabStripWidth` 是 tab 条内容渲染出来的实际宽度，只有 notice 态用得到。
    func size(for state: IslandState, tabStripWidth: CGFloat = 0) -> CGSize {
        switch state {
        case .idle:
            return CGSize(width: baseWidth + constants.idleSideBleed * 2,
                          height: geometry.menuBarHeight)

        case .running:
            return CGSize(width: baseWidth + constants.runningSideBleed * 2,
                          height: geometry.menuBarHeight)

        case .notice:
            // 取 running 宽度与 tab 条所需宽度的较大者，上限是 expanded 宽度。
            let runningWidth = size(for: .running).width
            let width = min(max(runningWidth, tabStripWidth), expandedWidth)
            return CGSize(width: width,
                          height: geometry.menuBarHeight + constants.tabStripHeight)

        case .expanded:
            return CGSize(width: expandedWidth,
                          height: geometry.menuBarHeight
                                + constants.tabStripHeight
                                + constants.contentHeight
                                + constants.inputBarHeight)
        }
    }

    // MARK: - 圆角

    func cornerRadii(for state: IslandState) -> IslandCornerRadii {
        // 无刘海屏是屏幕顶部的浮条，没有物理刘海可以嵌进去，内凹拐角退化为 0。
        IslandCornerRadii(bottom: constants.bottomCornerRadius,
                          inverted: geometry.hasNotch ? constants.invertedCornerRadius : 0)
    }

    // MARK: - 窗口 frame

    /// 承载岛的面板 frame，全局坐标（原点左下）。
    ///
    /// 面板**不随状态改变**，永远是最大态（expanded）的尺寸，岛在里面变形。
    /// 每帧改 NSWindow 的 frame 会抖，交给 SwiftUI 在固定画布里插值才跟手。
    ///
    /// 宽度额外留出两倍内凹半径 —— 内凹圆弧画在主体两侧之外，否则会被窗口边界切掉。
    var containerFrame: CGRect {
        let expanded = size(for: .expanded)
        let inverted = constants.invertedCornerRadius
        let width = expanded.width + inverted * 2
        return CGRect(x: geometry.islandCenterX - width / 2,
                      y: geometry.screenTopY - expanded.height,
                      width: width,
                      height: expanded.height)
    }
}
