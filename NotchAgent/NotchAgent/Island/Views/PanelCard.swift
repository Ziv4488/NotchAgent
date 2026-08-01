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

    /// 卡片是岛最底下那一层时，下面留出这么多黑边。
    /// 数值跟 `InputBar` 的 `.padding(.bottom, 8)` 对齐 —— 会话活着时下面没有输入框，
    /// 两种情况下岛的下边框应当一样宽。
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

    var body: some View {
        shape
            .fill(IslandTheme.panelFill)
            .overlay { shape.strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
    }
}
