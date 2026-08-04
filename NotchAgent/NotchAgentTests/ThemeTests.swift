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

    /// **卡片四边都得留出岛体的黑。**
    ///
    /// 有过一版让卡片铺到岛的下沿（下角跟着岛的圆角走）。用户看完的原话是
    /// 「我对月牙没有意见，我需要看起来是整个岛，而不是终端下方跟岛外的内容
    /// 没有边界」—— 顶到底之后岛的下沿就成了正文的边，桌面从字底下开始。
    /// 别再把这两个数改成 0。
    @Test("卡片四边都留黑边")
    func cardKeepsAMargin() {
        #expect(PanelCard.inset > 0)
        #expect(PanelCard.bottomInset > 0)
        // 展开态底下只有这一张卡（输入框 08-04 拆了），这圈黑边由它自己留。
        #expect(PanelCard.bottomInset == 8)
    }

    /// **卡片的圆角要和岛的下角同心。**
    ///
    /// 同心 = 半径差正好等于内缩量，两条弧线处处平行、黑边一圈一样宽。
    /// 卡片原来写死 10pt，比同心该有的圆得多，转角处的黑边比直边宽出一截 ——
    /// 用户 2026-08-02 报的「岛的圆角需与终端的圆角保持一致」就是这个。
    /// 别再改成一个写死的数。
    @Test("卡片圆角 = 岛的下角 − 内缩")
    func cardIsConcentricWithTheIsland() {
        let island = IslandConstants.default.bottomCornerRadius
        #expect(PanelCard.cardRadius == island - PanelCard.inset)
        #expect(PanelCard.cardRadius == 9)
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
