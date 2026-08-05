//
//  PanelCard.swift
//  NotchAgent
//
//  岛里那张比岛体浅一档的卡片：内容区、新建表单共用一张。
//

import SwiftUI

/// 内容区 / 新建表单的底板。
///
/// 岛体是纯黑（紧挨着物理刘海，浅一点就露接缝），这张卡片是 #1E1E1E ——
/// 长时间盯着读的那一块不能是纯黑。**四边都要留出岛体的黑**：
/// 左右各 `inset`，下面 `bottomInset`。
///
/// 中间试过一版让卡片一直铺到岛的下沿（下角跟着岛的圆角走，好消掉那两牙黑月牙）。
/// 方向是错的 —— 用户的原话是「我对月牙没有意见，我需要看起来是整个岛，
/// 而不是终端下方跟岛外的内容没有边界」。卡片顶到底之后，岛的下沿就成了终端
/// 正文的边，桌面直接从字底下开始，读起来是一块贴在屏幕上的终端、不是一座岛。
/// 留一圈黑边，岛才收得住。
struct PanelCard: View {
    /// 卡片左右各让出这么多，露出岛体的黑。
    static let inset: CGFloat = 7

    /// 卡片下面留出这么多黑边。
    ///
    /// 展开态底下**只有这一张卡**（输入框 2026-08-04 拆了，见
    /// `IslandConstants.retiredInputBarHeight`），所以这圈黑边永远由它自己留 ——
    /// 不再有「会话活着归内容区留、结束了归输入框留」那两条路。
    static let bottomInset: CGFloat = 8

    /// 卡片的圆角。**跟着岛的下角走，不是随便挑的一个数。**
    ///
    /// 卡片四边各内缩，要和岛的下角**同心**（两条弧线处处平行、黑边一圈一样宽），
    /// 半径就得比岛小一个内缩量：12 − 7 = **5**。
    ///
    /// 用户 2026-08-02 报的「岛的圆角需与终端的圆角保持一致」就是这个 ——
    /// 原来卡片写死 10pt，比同心该有的圆得多，于是转角处的黑边比直边宽出一截，
    /// 两条弧看着就不是一套的。写成算出来的，岛的圆角以后改了它也跟着走。
    static var cardRadius: CGFloat {
        max(2, IslandConstants.default.bottomCornerRadius - inset)
    }

    /// 底色跟着终端主题走（plan 4.3）。
    ///
    /// **这块底和终端的背景色是同一样东西** —— 终端自己的背景一直是 `.clear`
    /// （填了圆角就方），画出那块底的是这张卡片。所以换主题时变的是这里。
    var body: some View {
        let theme = ThemeStore.shared.theme
        shape
            .fill(theme.background.swiftUIColor)
            .overlay { shape.strokeBorder(theme.surfaceStroke, lineWidth: 0.5) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
    }
}
