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
