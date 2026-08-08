//
//  NotchShapeTests.swift
//  NotchAgentTests
//
//  内凹拐角的方向很容易画反，而反了在深色截图上几乎看不出来 —— 用几何断言钉死。
//

import Testing
import SwiftUI
@testable import NotchAgent

private let inverted: CGFloat = 8
private let bottom: CGFloat = 12
/// 画布：主体宽 200，左右各留 8 给内凹圆弧。
private let canvas = CGRect(x: 0, y: 0, width: 216, height: 60)

private func path(bottomRadius: CGFloat = bottom, invertedRadius: CGFloat = inverted) -> Path {
    NotchShape(bottomRadius: bottomRadius, invertedRadius: invertedRadius).path(in: canvas)
}

struct NotchShapeTests {

    /// 内凹圆弧和上沿相切，切点附近楔形宽度趋近 0，取样点别贴太近。
    /// 取主体边界外 4pt 处，测它在不同高度上是不是实心。
    private static let probeInset: CGFloat = 4

    @Test("内凹拐角向上张开：贴着上沿是实心，往下一个半径就空了")
    func flareOpensUpward() {
        let p = path()
        let x = Self.probeInset

        // 左侧：紧贴上沿，主体外 4pt 处仍是黑的 —— 楔形在这里张开了。
        #expect(p.contains(CGPoint(x: canvas.minX + x, y: canvas.minY + 0.2)))
        // 往下走到接近一个内凹半径，同一个 x 已经退到主体之外。
        #expect(!p.contains(CGPoint(x: canvas.minX + x, y: canvas.minY + inverted - 2)))

        // 右侧镜像。
        #expect(p.contains(CGPoint(x: canvas.maxX - x, y: canvas.minY + 0.2)))
        #expect(!p.contains(CGPoint(x: canvas.maxX - x, y: canvas.minY + inverted - 2)))
    }

    @Test("内凹边界单调：y 越大，实心区的左边界越靠右")
    func flareBoundaryIsMonotonic() {
        let p = path()

        /// 在高度 y 上从左往右找第一个实心点。
        func leftBoundary(at y: CGFloat) -> CGFloat {
            var x = canvas.minX
            while x < canvas.minX + inverted + 1 {
                if p.contains(CGPoint(x: x, y: y)) { return x }
                x += 0.05
            }
            return canvas.minX + inverted
        }

        var previous = leftBoundary(at: canvas.minY + 0.1)
        for y in stride(from: canvas.minY + 1, through: canvas.minY + inverted, by: 1) {
            let current = leftBoundary(at: y)
            #expect(current >= previous - 0.05, "y=\(y): \(current) 应当不小于 \(previous)")
            previous = current
        }
        // 走完一个内凹半径后应当正好落在主体边上。
        #expect(abs(previous - (canvas.minX + inverted)) < 0.5)
    }

    @Test("主体两侧笔直：内凹半径以下的边界就是主体边")
    func bodyEdgesAreStraight() {
        let p = path()
        let bodyLeft = canvas.minX + inverted
        let bodyRight = canvas.maxX - inverted
        for y in stride(from: canvas.minY + inverted + 1, to: canvas.maxY - bottom - 1, by: 4) {
            #expect(p.contains(CGPoint(x: bodyLeft + 1, y: y)), "y=\(y)")
            #expect(!p.contains(CGPoint(x: bodyLeft - 1, y: y)), "y=\(y)")
            #expect(p.contains(CGPoint(x: bodyRight - 1, y: y)), "y=\(y)")
            #expect(!p.contains(CGPoint(x: bodyRight + 1, y: y)), "y=\(y)")
        }
    }

    @Test("底部是圆角：贴着主体的下角是空的，往内一点是实心的")
    func bottomCornersAreRounded() {
        let p = path()
        let bodyLeft = canvas.minX + inverted
        #expect(!p.contains(CGPoint(x: bodyLeft + 1, y: canvas.maxY - 1)))
        #expect(p.contains(CGPoint(x: bodyLeft + bottom + 2, y: canvas.maxY - 1)))
    }

    @Test("内凹半径为 0 时退化：上沿两角变成直角，无刘海屏走这条路")
    func degeneratesWithoutInvertedRadius() {
        let p = path(invertedRadius: 0)
        #expect(p.contains(CGPoint(x: canvas.minX + 1, y: canvas.minY + 1)))
        #expect(p.contains(CGPoint(x: canvas.minX + 1, y: canvas.minY + 10)))
        #expect(p.contains(CGPoint(x: canvas.maxX - 1, y: canvas.minY + 10)))
    }

    @Test("两个半径都为 0 时就是矩形")
    func degeneratesToRectangle() {
        let p = path(bottomRadius: 0, invertedRadius: 0)
        #expect(p.contains(CGPoint(x: canvas.minX + 1, y: canvas.maxY - 1)))
        #expect(p.contains(CGPoint(x: canvas.maxX - 1, y: canvas.maxY - 1)))
    }

    @Test("半径超过可用空间时被夹住，路径不自交、不越界")
    func radiiAreClamped() {
        let p = path(bottomRadius: 999, invertedRadius: 999)
        #expect(canvas.insetBy(dx: -1, dy: -1).contains(p.boundingRect))
        #expect(!p.isEmpty)
    }

    @Test("路径不超出画布")
    func staysInsideCanvas() {
        let p = path()
        #expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(p.boundingRect))
    }
}

