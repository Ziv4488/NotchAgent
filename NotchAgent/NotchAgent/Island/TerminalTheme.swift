//
//  TerminalTheme.swift
//  NotchAgent
//
//  终端配色（plan「4.3 的范围」）。只做终端这一层。
//

import AppKit
import SwiftUI
import SwiftTerm

/// 一套终端配色：ANSI 16 色 + 前景 / 背景 / 光标。
///
/// **背景色就是内容区那块底。** 终端自己的 `nativeBackgroundColor` 一直是 `.clear`
/// （见 `TerminalPane.style`）—— 真正画出那块底的是内容区的圆角卡片 `PanelCard`，
/// 终端自己填的话四个角就方了。所以主题的 `background` 落在卡片上、不落在终端上：
/// 用户看到的是一块底，代码里分两处。
///
/// **岛体不参与主题。** 它紧挨着物理刘海，浅色岛配黑刘海视觉上是破的
/// （plan 4.3「岛体保持纯黑不可配」）。这里一个字都不碰 `IslandTheme` 的岛体常量。
struct TerminalTheme: Codable, Equatable {
    /// sRGB，各分量 0...1。
    ///
    /// 存 sRGB 而不是存 `NSColor`：主题要能写进 UserDefaults、要能从 iTerm/Ghostty
    /// 的文件里读出来，两头都是裸数字，中间夹一个带色彩空间的对象只会让「同一个值
    /// 存进去和读出来不一样」。
    struct RGB: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red.clamped()
            self.green = green.clamped()
            self.blue = blue.clamped()
        }

        /// `#RRGGBB` 或 `RRGGBB`。解析不出来返回 nil —— 导入的文件是外部输入，
        /// 不能默默当成黑色，那样用户会看到一套全黑的主题而不知道文件坏了。
        init?(hex: String) {
            var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            self.init(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        var swiftUIColor: SwiftUI.Color {
            SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }

        /// SwiftTerm 的分量是 0...65535 的 `UInt16`。
        var terminalColor: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(red * 65535),
                            green: UInt16(green * 65535),
                            blue: UInt16(blue * 65535))
        }
    }

    var name: String
    var background: RGB
    var foreground: RGB
    var cursor: RGB
    /// 恰好 16 个：0–7 暗色，8–15 亮色。
    var ansi: [RGB]

    /// 导入来的主题可能缺色。**不满 16 色就不往终端里装** ——
    /// `installColors` 对长度不是 16 的数组直接什么都不做，装了等于悄悄没生效。
    var isValid: Bool { ansi.count == 16 }
}

// MARK: - 画在这块底上的其它东西

/// 内容区那张卡片上除了终端，还有会话结束卡、提示卡和卡片自己那圈描边。
/// 它们原来一律是「白色的某个透明度」—— 那是**假定了底一定是深色**。
///
/// 2026-08-05 加浅色主题之后这个假定不成立了：白字打在 `#FAFAFA` 上是看不见的。
/// 所以墨色跟着底色翻。
extension TerminalTheme {
    /// sRGB 相对亮度（WCAG 那套）。**不是** `brightnessComponent` ——
    /// 后者是 HSB 的 B，只看最大分量，黄色和白色在它眼里一样亮。
    var backgroundLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(background.red)
            + 0.7152 * channel(background.green)
            + 0.0722 * channel(background.blue)
    }

    /// 底够亮时画在上面的东西要翻成黑的。
    var prefersDarkInk: Bool { backgroundLuminance > 0.5 }

    private var ink: SwiftUI.Color { prefersDarkInk ? .black : .white }

    /// 三档墨色 + 描边 + 按钮底。
    ///
    /// **浅底那一侧的透明度都调高了。** 同样是 0.32，白色压在深底上比黑色压在
    /// 浅底上显眼得多 —— 人眼对亮的一侧更敏感。直接照搬会让浅色主题上的
    /// 次要文字淡到读不出来。
    var onSurfaceBright: SwiftUI.Color { ink.opacity(0.95) }
    var onSurfaceDim: SwiftUI.Color { ink.opacity(prefersDarkInk ? 0.70 : 0.55) }
    var onSurfaceFaint: SwiftUI.Color { ink.opacity(prefersDarkInk ? 0.48 : 0.32) }
    var surfaceStroke: SwiftUI.Color { ink.opacity(prefersDarkInk ? 0.14 : 0.07) }
    var controlFill: SwiftUI.Color { ink.opacity(prefersDarkInk ? 0.10 : 0.14) }
    var controlLabel: SwiftUI.Color { ink.opacity(0.90) }
}

// MARK: - 内置预设

extension TerminalTheme {
    /// 菜单里列出来的三组。第一组是「默认」，即这个 app 一直以来的样子。
    ///
    /// **2026-08-05 用户定的这个组合**：默认、一组深色（Dracula）、一组浅色（One Light）。
    /// 原来那组 Tokyo Night 当天被否掉（「东京夜这个颜色不要」）。
    static let builtins: [TerminalTheme] = [.notchDefault, .dracula, .oneLight]

    static func builtin(named name: String) -> TerminalTheme? {
        builtins.first { $0.name == name }
    }

    /// 默认主题 —— **就是 4.3 之前那套值，换了个存法。**
    ///
    /// 前景与光标取自 `IslandTheme.terminalForeground` / `terminalCaret`，
    /// 背景取自 `IslandTheme.panelFill`（#1E1E1E，用户 2026-08-01 定的，
    /// 理由见那条注释：纯黑底配亮字看久了眼睛发涩）。
    ///
    /// 前景那一项**差了不到 1/255**：原来是 `NSColor(white: 0.92)`，落在通用灰
    /// 色彩空间里；这里统一成 sRGB 的 `#EBEBEB`。两者的传递函数在 0.92 处几乎重合，
    /// 差值低于这个项目自己的测量分辨率（@2x 截图上的 1/255），肉眼无从分辨。
    ///
    /// **ANSI 16 色这一栏是新的，但装进去的值不是新的。** 4.3 之前我们从来没设过
    /// 调色板，终端走的是 SwiftTerm 自带的默认 —— 而它的默认是
    /// `Color.terminalAppColors`（`Terminal.init` 里 `installedColors` 的初值，
    /// 即 macOS 终端 app 那套）。那 16 个值在 SwiftTerm 里是 internal、取不到，
    /// 所以照抄进来。**照抄的目的就是让「默认」这一档一个像素都不变**，
    /// 同时让用户从 Dracula 切回来时有东西可切。
    static let notchDefault = TerminalTheme(
        name: "默认",
        background: RGB(hex: "1E1E1E")!,
        foreground: RGB(hex: "EBEBEB")!,
        cursor: RGB(hex: "D97857")!,
        ansi: [
            "000000", "C23621", "25BC24", "ADAD27",
            "492EE1", "D338D3", "33BBC8", "CBCCCD",
            "818383", "FC391F", "31E722", "EAEC23",
            "5833FF", "F935F8", "14F0F0", "E9EBEB",
        ].map { RGB(hex: $0)! })

    static let dracula = TerminalTheme(
        name: "Dracula",
        background: RGB(hex: "282A36")!,
        foreground: RGB(hex: "F8F8F2")!,
        cursor: RGB(hex: "F8F8F2")!,
        ansi: [
            "21222C", "FF5555", "50FA7B", "F1FA8C",
            "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
            "6272A4", "FF6E6E", "69FF94", "FFFFA5",
            "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF",
        ].map { RGB(hex: $0)! })

    /// 浅色那一组（用户 2026-08-05 要的）。
    ///
    /// **这一组是对 plan 4.3 一条旧结论的推翻，是用户当天定的。** 原话那条是
    /// 「岛体保持纯黑不可配 …… 浅色岛配黑刘海视觉上是破的」—— 那说的是**岛体**，
    /// 岛体到现在也没变，仍是纯黑。这里浅的是**内容区**，也就是终端那块底。
    /// 两者挨着，浅内容区 + 纯黑岛的对比确实比深色主题时强烈得多，这一点
    /// 只能人眼判（§15.13）。
    ///
    /// 选 One Light 而不是更有名的 Solarized Light：后者的正文色是 `#657B83`，
    /// 打在 `#FDF6E3` 上对比度只有 **4.2** —— 那是它刻意的低对比风格，
    /// 但岛上的终端字号才 12pt，读久了费劲。One Light 是 **10.9**。
    static let oneLight = TerminalTheme(
        name: "One Light",
        background: RGB(hex: "FAFAFA")!,
        foreground: RGB(hex: "383A42")!,
        cursor: RGB(hex: "526FFF")!,
        ansi: [
            "000000", "E45649", "50A14F", "C18401",
            "4078F2", "A626A4", "0184BC", "A0A1A7",
            "5C6370", "E45649", "50A14F", "C18401",
            "4078F2", "A626A4", "0184BC", "FFFFFF",
        ].map { RGB(hex: $0)! })
}

private extension Double {
    func clamped() -> Double { Swift.min(1, Swift.max(0, self)) }
}
