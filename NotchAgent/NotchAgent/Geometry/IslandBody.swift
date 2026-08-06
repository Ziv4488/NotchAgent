//
//  IslandBody.swift
//  NotchAgent
//
//  岛的填充轮廓：`NotchShape`，中间可能挖掉贴附窗口那一块。
//

import SwiftUI

/// 岛体。`hole` 非空时中间是个洞，**按 even-odd 填**。
///
/// 为什么要挖洞：岛压在第三方窗口之上（层级 `statusBar + 1`，见 `NotchWindow`），
/// 岛体又是不透明的纯黑 —— 直接铺满就把贴在下面的窗口整个盖没了。
/// 08-07 之前的做法是让岛缩成只剩状态带 + tab 条，把内容区整块让出去；
/// 用户实机后说「感觉不是一个东西，没有在岛内的感觉」—— 窗口紧贴着岛的下沿，
/// 自己的标题栏、圆角、阴影全露在外面，读起来是两个窗口叠着。
///
/// 改成挖洞之后，岛照常铺满，洞的四周那一圈黑边就是「框」，窗口嵌在里面。
///
/// 填充用 `FillStyle(eoFill: true)`。**但这不是它今天能挖出洞的原因** ——
/// 实测 `NotchShape` 和 `addRoundedRect` 绕向正好相反，nonzero 也照样挖得出。
/// 写明 even-odd 是不想让「洞在不在」依赖一个没人写下来、也没人守着的绕向：
/// 哪天有人把 `NotchShape` 的画法反过来，nonzero 那条路会**静悄悄地**把洞
/// 填成黑的，而那正是「窗口不见了」这个最坏的表现。
///
/// 代价是这个参数**没有测试盯着**（删了画面一个像素都不变，没法分辨）。
/// 留它是买个保险，不是买个断言。
struct IslandBody: Shape {
    var bottomRadius: CGFloat
    var invertedRadius: CGFloat
    /// 挖掉的那块，坐标和 `path(in:)` 收到的 `rect` 同一套。空矩形表示不挖。
    var hole: CGRect = .zero
    /// 洞的圆角。**要比目标窗口自己的圆角大一点**，理由见
    /// `IslandConstants.attachHoleRadius`。
    var holeRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = NotchShape(bottomRadius: bottomRadius, invertedRadius: invertedRadius)
            .path(in: rect)
        guard !hole.isEmpty else { return path }
        path.addRoundedRect(in: hole,
                            cornerSize: CGSize(width: holeRadius, height: holeRadius),
                            style: .continuous)
        return path
    }
}
