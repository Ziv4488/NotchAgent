//
//  AXCoordinates.swift
//  NotchAgent
//
//  AppKit 的坐标（原点左下）和 AX 的坐标（原点左上）之间那一下翻转。
//

import AppKit

/// **这两套坐标长得一模一样，翻错了不会报错、只会把窗口放到屏幕另一头。**
///
/// AppKit（`NSScreen.frame`、`NSWindow.frame`、`IslandMetrics` 里的一切）原点在
/// 左下、y 向上；AX 的 `AXPosition` 跟 `CGWindowList` 一样，原点在**主显示器的
/// 左上**、y 向下。两边都是 `CGRect`，编译器帮不上忙，所以这一下单独抽出来，
/// 并且有测试钉着。
///
/// 基准是**主显示器**的上沿，不是当前这块屏的 —— 副屏在主屏上方时它的 y 是负的。
enum AXCoordinates {

    /// 主显示器的上沿（AppKit 坐标）。`NSScreen.screens` 的第一块永远是主屏。
    static var primaryTopY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// AppKit 矩形 → AX 矩形。
    static func topLeft(_ rect: CGRect, primaryTopY: CGFloat = primaryTopY) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryTopY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// AX 矩形 → AppKit 矩形。读回来的实得 frame 要走这一下才能跟岛的几何比。
    ///
    /// **和 `topLeft` 是同一个函数** —— 翻转是它自己的逆运算
    /// （`T - ((T - y - h) + h) == y`）。这里不合并成一个，是因为调用处写
    /// `AXCoordinates.topLeft(rect)` 还是 `bottomLeft(rect)` 说明的是**方向**，
    /// 而方向恰恰是这段代码唯一会写错的地方。
    static func bottomLeft(_ rect: CGRect, primaryTopY: CGFloat = primaryTopY) -> CGRect {
        topLeft(rect, primaryTopY: primaryTopY)
    }
}
