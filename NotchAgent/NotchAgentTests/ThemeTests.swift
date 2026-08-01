//
//  ThemeTests.swift
//  NotchAgentTests
//
//  配色里那几个「不能被顺手改回去」的值。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

@Suite("配色")
@MainActor
struct ThemeTests {

    private func srgb(_ color: Color) throws -> NSColor {
        try #require(NSColor(color).usingColorSpace(.sRGB))
    }

    /// 内容区底色**必须是不透明的**。
    ///
    /// 老值是 `Color.white.opacity(0.045)` —— 叠在纯黑的岛上算出来 #0B0B0B，
    /// 也就是「几乎纯黑」。用户 2026-08-01 报的「太黑了，看得人眼疼」就是它。
    /// 半透明白这种写法一回来，这条立刻红。
    @Test("内容区底色是不透明的 #1E1E1E")
    func contentBackgroundIsOpaqueCharcoal() throws {
        let color = try srgb(IslandTheme.panelFill)
        #expect(color.alphaComponent == 1)
        for component in [color.redComponent, color.greenComponent, color.blueComponent] {
            #expect(abs(component - 30.0 / 255) < 0.002)
        }
    }

    /// 上下两头都要卡住：
    ///
    /// - 太暗 → 又变回「亮字打在纯黑上」，就是用户报的那个眼睛发涩；
    /// - 太亮 → 内容区和纯黑的岛体之间会出现一道明显的台阶。
    ///   岛体不能跟着一起提亮 —— 它紧挨着物理刘海，浅一点就露接缝
    ///   （计划 4.3：「岛体保持纯黑不可配」）。
    @Test("内容区比纯黑亮，但没亮到发灰")
    func contentBackgroundStaysInRange() throws {
        let brightness = try srgb(IslandTheme.panelFill).brightnessComponent
        #expect(brightness > 0.08)
        #expect(brightness < 0.22)
    }

    /// 终端正文是打在那个底色上的，底色提亮之后对比度不能塌掉。
    /// WCAG 的正文门槛是 4.5:1；11pt 等宽小字该更宽裕，这里卡在 7:1（AAA）。
    @Test("终端正文对内容区底色的对比度够高")
    func terminalForegroundIsReadable() throws {
        let text = try #require(IslandTheme.terminalForeground.usingColorSpace(.sRGB))
        let background = try srgb(IslandTheme.panelFill)
        #expect(contrastRatio(text, on: background) > 7)
    }

    /// 用户 2026-08-01 拿了一张「就要这么大」的截图来对齐：
    /// 那上面等宽格宽 7.5pt、汉字墨高 11.5pt，岛上 11pt 时是 7.1 / 10.0。
    /// 别再悄悄退回 11 —— 那正是他说「字体有点小」的那一档。
    @Test("终端字号不小于 12，而且是等宽的")
    func terminalFontIsBigEnough() {
        #expect(IslandTheme.terminalFont.pointSize >= 12)
        #expect(IslandTheme.terminalFont.isFixedPitch)
    }

    /// 内容区铺到岛下沿时，两个下角要和岛**同心**。
    ///
    /// 卡片左右各内缩 7pt，半径就得跟着小 7pt；用岛自己的 12 会在下面
    /// 两角各留一牙黑月牙 —— 底色提亮之后那两牙看着就是「终端下面多了一圈边框」。
    @Test("铺到底时的下角半径 = 岛的半径 − 内缩", arguments: [
        (12.0, 5.0), (7.0, 0.0), (4.0, 0.0), (20.0, 13.0),
    ])
    func bleedingBottomRadius(islandBottom: Double, expected: Double) {
        let actual = PanelCard.bleedingBottomRadius(islandBottom: CGFloat(islandBottom))
        #expect(actual == CGFloat(expected))
    }

    /// WCAG 2.1 的相对亮度与对比度公式。
    private func contrastRatio(_ a: NSColor, on b: NSColor) -> Double {
        let (light, dark) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (light + 0.05) / (dark + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
