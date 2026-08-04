//
//  NotchShape.swift
//  NotchAgent
//
//  岛的轮廓：顶边贴齐屏幕上沿，底部两个圆角，上沿两侧各一个内凹拐角。
//

import SwiftUI

/// 岛的轮廓。
///
/// 坐标约定：传进来的 `rect` 是**整个窗口**，比岛主体左右各宽 `inverted`，
/// 那两条边就是内凹圆弧占的地方。主体本身居中。
///
/// 内凹拐角是一段向外凸的圆弧，让岛看起来像从菜单栏"长"出来的，
/// 和 macOS 自家的刘海过渡一致。
struct NotchShape: Shape {
    /// 底部圆角半径。
    var bottomRadius: CGFloat
    /// 上沿两侧内凹拐角半径。0 表示退化成普通圆角矩形（无刘海屏）。
    var invertedRadius: CGFloat

    /// 收不收顶边那条直线。
    ///
    /// **只对描边有意义。** 填充和命中测试遇到开放子路径会隐式闭合，
    /// 两种取值画出来、点出来都一模一样；`stroke` 才分得出来 ——
    /// 关掉之后那条线从左上内凹弧的起点画到右上内凹弧的终点就停，顶边不描。
    ///
    /// 岛的顶边正好压在屏幕物理上沿，描上去只有内侧半条露得出来，
    /// 读起来是刘海底下横着一道亮痕（用户 2026-08-04：「上方边缘不要边界」）。
    var closesTop = true

    /// 让 spring 动画能同时插值两个半径。
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, invertedRadius) }
        set {
            bottomRadius = newValue.first
            invertedRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 半径不能超过可用空间的一半，否则圆弧会自交。
        let inverted = max(0, min(invertedRadius, rect.width / 4))
        let bodyWidth = rect.width - inverted * 2
        let bottom = max(0, min(bottomRadius, min(bodyWidth, rect.height) / 2))

        let left = rect.minX + inverted      // 主体左边
        let right = rect.maxX - inverted     // 主体右边
        let top = rect.minY
        let bot = rect.maxY

        // 左上：从窗口左上角起，一段向右下凸的圆弧接到主体左边。
        path.move(to: CGPoint(x: rect.minX, y: top))
        if inverted > 0 {
            path.addArc(center: CGPoint(x: rect.minX, y: top + inverted),
                        radius: inverted,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(0),
                        clockwise: false)
        }

        // 左边下行到左下圆角。
        path.addLine(to: CGPoint(x: left, y: bot - bottom))
        if bottom > 0 {
            path.addArc(center: CGPoint(x: left + bottom, y: bot - bottom),
                        radius: bottom,
                        startAngle: .degrees(180),
                        endAngle: .degrees(90),
                        clockwise: true)
        }

        // 底边到右下圆角。
        path.addLine(to: CGPoint(x: right - bottom, y: bot))
        if bottom > 0 {
            path.addArc(center: CGPoint(x: right - bottom, y: bot - bottom),
                        radius: bottom,
                        startAngle: .degrees(90),
                        endAngle: .degrees(0),
                        clockwise: true)
        }

        // 右边上行到右上内凹拐角。
        path.addLine(to: CGPoint(x: right, y: top + inverted))
        if inverted > 0 {
            path.addArc(center: CGPoint(x: rect.maxX, y: top + inverted),
                        radius: inverted,
                        startAngle: .degrees(180),
                        endAngle: .degrees(270),
                        clockwise: false)
        }

        if closesTop { path.closeSubpath() }
        return path
    }
}

#Preview("三档圆角") {
    // 半径 8/12/26 三档并排，肉眼确认内凹拐角与主体连续、无缝隙。
    // 最后一组是 0 —— 无刘海屏应该退化成普通圆角矩形。
    VStack(spacing: 0) {
        ForEach([(12.0, 8.0), (18.0, 11.0), (26.0, 14.0), (12.0, 0.0)], id: \.0) { radii in
            ZStack(alignment: .top) {
                Color(white: 0.18)
                NotchShape(bottomRadius: radii.0, invertedRadius: radii.1)
                    .fill(.black)
                    .frame(width: 300 + radii.1 * 2, height: 44)
            }
            .frame(height: 90)
        }
    }
    .frame(width: 420)
}
