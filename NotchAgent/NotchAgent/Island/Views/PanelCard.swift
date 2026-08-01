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
/// 长时间盯着读的那一块不能是纯黑。两者之间左右各留 `inset` 的黑边，
/// 是刻意留的，用户点名要保留。
struct PanelCard: View {
    /// 下沿的圆角。**它不总是一样**：底下还摞着别的东西时是普通卡片；
    /// 自己就是岛最底下那一层时要贴到岛的下沿去（见 `bleedingBottomRadius`）。
    var bottomRadius: CGFloat = PanelCard.cardRadius

    /// 卡片左右各让出这么多，露出岛体的黑。
    static let inset: CGFloat = 7
    static let cardRadius: CGFloat = 10

    /// 卡片铺到岛下沿时，它的下角该有多圆。
    ///
    /// 卡片左右各内缩 `inset`，要和岛的下角**同心**，半径就得跟着小 `inset`。
    /// 用卡片自己那 10pt 会在下面两角各留一牙黑月牙 —— 底色提亮之后
    /// 那两牙看着就是「终端下面多了一圈边框」，用户报过两次。
    static func bleedingBottomRadius(islandBottom: CGFloat) -> CGFloat {
        max(0, islandBottom - inset)
    }

    var body: some View {
        shape
            .fill(IslandTheme.panelFill)
            .overlay { shape.strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5) }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Self.cardRadius,
                               bottomLeadingRadius: bottomRadius,
                               bottomTrailingRadius: bottomRadius,
                               topTrailingRadius: Self.cardRadius,
                               style: .continuous)
    }
}
