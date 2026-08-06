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
    ///
    /// 每侧要放下「圆点 + 一行字」：10pt 内边距 + 5pt 点 + 5pt 间距 = 20pt 固定开销，
    /// 剩下 60pt 给文字 —— 11pt 系统字下约 10 个英文字符 / 5 个汉字（实测 "session.ts" 54pt）。
    /// 再宽就纯粹是在挡菜单栏了（见 spec 3.1 的「代价」）。
    var idleSideBleed: CGFloat = 80
    /// running 态在刘海左右各多出的宽度。比 idle 宽一档，
    /// 让「闲着」和「在跑」一眼分得开，右侧也放得下计时 + 窗口数。
    var runningSideBleed: CGFloat = 88
    /// expanded 态的默认宽度（可拖拽调整并记住）。约等于 80 列终端。
    var expandedWidth: CGFloat = 560
    /// tab 条高度。
    var tabStripHeight: CGFloat = 34
    /// expanded 态内容区的默认高度（可拖拽调整并记住）。
    ///
    /// **342 = 原来的 320 + 用量条那 22。** 用量条 2026-08-01 拆掉了，但它的高度
    /// 一直还留在 `expandedChromeHeight` 里 —— 岛照旧按「有那条 bar」的尺寸开，
    /// 多出来的 22pt 被内容区（`maxHeight: .infinity`）默默吃掉。也就是说
    /// 内容区**实际**一直是 342，只有常量在说 320。这里把那 22pt 从 chrome
    /// 挪回内容区，岛的总高一个像素都没变，但每个数都对得上自己的名字了。
    var contentHeight: CGFloat = 342
    /// **拆掉的那条输入框留下的 44pt。**
    ///
    /// 输入框 2026-08-04 拆了（它只在没有活进程时才画，而那时它写进去的 PTY
    /// 是死的，按回车什么都不会发生）。这 44pt **故意留在总高里**，被内容区
    /// 吃掉 —— 和用量条那 22pt 当初的处境一样。
    ///
    /// **但这次没像用量条那样把它挪进 `contentHeight`。** 那个数是用户拖出来的、
    /// 存在 `UserDefaults` 里的（`Preferences.expandedContentHeight`）：口径一改，
    /// 存过尺寸的人下次开岛就矮 44pt，而存量值分不出是老口径还是新口径。
    /// 名字改成 `retired…` 是为了别再有人以为下面画着一条输入框。
    var retiredInputBarHeight: CGFloat = 44
    /// 无刘海屏的宽度基准，替代刘海宽度（spec 3.4）。
    var fallbackNotchWidth: CGFloat = 200

    /// 底部圆角半径。
    ///
    /// **16 是量出来的，不是挑的。** 用户 2026-08-04 给了一张 macOS 26 系统窗口的
    /// 截图（@2x），拿 SwiftUI 自己的 `RoundedRectangle(cornerRadius:style:.continuous)`
    /// 路径去套那条轮廓，16pt 时残差 0.8pt（在抗锯齿噪声里），12pt 和 20pt 都差着
    /// 好几个像素。16 也正是 macOS 26 的系统窗口圆角。
    ///
    /// 卡片的圆角跟着它走（`PanelCard.cardRadius` = 这个 − 7pt 内缩），改这里
    /// 卡片自己会跟上，两条弧继续同心。
    var bottomCornerRadius: CGFloat = 16
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

    /// expanded 尺寸是用户可拖拽调整的，覆盖 constants 里的默认值。
    var expandedWidth: CGFloat
    var expandedContentHeight: CGFloat

    init(geometry: ScreenGeometryProviding,
         constants: IslandConstants = .default,
         expandedWidth: CGFloat? = nil,
         expandedContentHeight: CGFloat? = nil) {
        self.geometry = geometry
        self.constants = constants
        self.expandedWidth = expandedWidth ?? constants.expandedWidth
        self.expandedContentHeight = expandedContentHeight ?? constants.contentHeight
    }

    /// expanded 态里内容区之外的固定开销。
    ///
    /// 真的画出来的只有前两样：状态带 + tab 条。第三样是**已经拆掉的输入框**
    /// 留下的 44pt（见 `retiredInputBarHeight`），它还算在这里，那块地方
    /// 由内容区吃下去。曾经还有个 `usageBarHeight`（22），用量条拆掉时把它
    /// 挪进了 `contentHeight`；这次没这么办，理由写在 `retiredInputBarHeight` 上。
    var expandedChromeHeight: CGFloat {
        geometry.menuBarHeight + constants.tabStripHeight + constants.retiredInputBarHeight
    }

    /// 宽度基准：有刘海取刘海实际宽度，无刘海取固定值。
    var baseWidth: CGFloat {
        geometry.notchWidth ?? constants.fallbackNotchWidth
    }

    // MARK: - 尺寸

    /// `tabStripWidth` 是 tab 条内容渲染出来的实际宽度，只有 notice 态用得到。
    ///
    /// `chromeOnly` 是选中 app tab 时那一档：内容区整块让给真实窗口，
    /// 岛只剩状态带 + tab 条。**岛体是不透明的 `.fill(.black)`**，
    /// 不缩的话直接把贴在下面的窗口盖没了。
    func size(for state: IslandState, tabStripWidth: CGFloat = 0,
              chromeOnly: Bool = false) -> CGSize {
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
                          height: chromeOnly ? chromeOnlyHeight
                                             : expandedChromeHeight + expandedContentHeight)
        }
    }

    // MARK: - 圆角

    func cornerRadii(for state: IslandState) -> IslandCornerRadii {
        // 无刘海屏是屏幕顶部的浮条，没有物理刘海可以嵌进去，内凹拐角退化为 0。
        IslandCornerRadii(bottom: constants.bottomCornerRadius,
                          inverted: geometry.hasNotch ? constants.invertedCornerRadius : 0)
    }

    // MARK: - 可拖拽范围

    /// 太窄终端排不下字，太宽就把整个桌面盖住了。
    var expandedWidthRange: ClosedRange<CGFloat> {
        420...max(420, geometry.screenFrame.width - 160)
    }

    /// 下限 182 而不是 160：`contentHeight` 的口径变了（见上面那两处），
    /// 同一个「岛能缩到多矮」换算过来就是 160 + 22。拖到最矮时岛的高度不变。
    var expandedContentHeightRange: ClosedRange<CGFloat> {
        182...max(182, geometry.screenFrame.height * 0.85 - expandedChromeHeight)
    }

    /// 这块屏幕上岛能达到的最大尺寸。面板按它开，之后全程不动。
    var maxExpandedSize: CGSize {
        CGSize(width: expandedWidthRange.upperBound,
               height: expandedChromeHeight + expandedContentHeightRange.upperBound)
    }

    // MARK: - 窗口 frame

    /// 承载岛的面板 frame，全局坐标（原点左下）。
    ///
    /// 面板**既不随状态改变、也不随拖拽改变**，一开就是这块屏幕上岛能达到的最大尺寸，
    /// 岛在里面变形。两个理由：
    ///
    /// 1. 状态切换时每帧改 NSWindow 的 frame 会抖，交给 SwiftUI 在固定画布里插值才跟手。
    /// 2. 岛是相对屏幕中线对称的 —— 拖宽时窗口原点要左移、内容要在窗口里保持居中，
    ///    这两件事一旦落到不同的绘制事务里就会看见一帧错位，也就是拖动时的闪烁。
    ///    面板全程不动，这个问题从根上不存在。
    ///
    /// 代价是一大块透明画布压在屏幕上半部，全靠 `NotchHostingView` 的轮廓命中测试
    /// 把点击放行下去 —— 那个命中测试因此是**必需**的，不是优化。
    ///
    /// 画布比岛能长到的最大尺寸还要大出两圈：
    ///
    /// 1. 左右各一个**内凹半径** —— 上沿那两段圆弧画在主体两侧之外。
    /// 2. 左右和下面再各一个 `IslandTheme.edgeShadowMargin` —— 外沿的阴影要有地方
    ///    化干净。窗口画不到自己 frame 之外，留窄了阴影就被齐齐切断，
    ///    岛外面平白多出一条刀切的黑边（用户 2026-08-04 拖到最大宽度时报的）。
    ///
    /// **上面不留**：岛的顶边压在屏幕物理上沿，往上让出来的地方在屏幕外。
    /// 内容区在屏幕上的位置，**原点左下**（和 `containerFrame` 同一套坐标）。
    ///
    /// 贴附的第三方窗口占的就是这块地方（plan 3.3）：选中 app tab 时岛只画
    /// 状态带 + tab 条，往下这一整块让给真实窗口，看起来就像是岛的内容。
    ///
    /// 高度是「岛的总高减去状态带和 tab 条」，也就是 `retiredInputBarHeight`
    /// 加上 `expandedContentHeight` —— 跟 CLI tab 的内容区**占的是同一块地方**，
    /// 所以两种 tab 之间来回切，岛的整体轮廓不变。
    ///
    /// **喂给 AX 之前要翻成原点左上**，见 `AXCoordinates.topLeft`。
    var contentRectOnScreen: CGRect {
        let size = size(for: .expanded)
        let chrome = geometry.menuBarHeight + constants.tabStripHeight
        let height = size.height - chrome
        return CGRect(x: geometry.islandCenterX - size.width / 2,
                      y: geometry.screenTopY - size.height,
                      width: size.width,
                      height: height)
    }

    /// 选中 app tab 时岛自己的高度：只剩状态带 + tab 条。
    ///
    /// 内容区那一整块交给了真实窗口，岛不能再在上面盖一层黑
    /// （岛体是不透明的 `.fill(.black)`，盖上去就把窗口挡没了）。
    var chromeOnlyHeight: CGFloat {
        geometry.menuBarHeight + constants.tabStripHeight
    }

    var containerFrame: CGRect {
        let maxSize = maxExpandedSize
        let margin = IslandTheme.edgeShadowMargin
        let width = maxSize.width + constants.invertedCornerRadius * 2 + margin * 2
        let height = maxSize.height + margin
        return CGRect(x: geometry.islandCenterX - width / 2,
                      y: geometry.screenTopY - height,
                      width: width,
                      height: height)
    }
}
