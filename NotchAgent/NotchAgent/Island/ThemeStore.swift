//
//  ThemeStore.swift
//  NotchAgent
//
//  当前生效的终端主题与字体，以及把它装进终端视图（plan「4.3 的范围」）。
//

import AppKit
import Observation
import SwiftTerm

/// 当前的终端配色与字体。
///
/// **做成 `@Observable` 的单例。** 内容区那块底色（`PanelCard`）是 SwiftUI 画的，
/// 而终端是 AppKit 视图 —— 一次换主题要同时推动两边。视图这边靠 `@Observable`
/// 自动重画，终端那边靠 `apply(to:)` 主动装一遍。
///
/// 走单例而不是顺着视图树传：主题是**整个岛只有一份**的东西，而
/// `PanelCard()` 现在在三处被无参数地构造（终端、结束卡、新建表单）。
/// 为一个全局视觉设置在三条路径上加参数，不如让它像 `IslandTheme` 一样可直接取用。
/// 测试要自己的一份时构造一个新的 `ThemeStore(preferences:)` 即可。
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private let preferences: Preferences

    /// 当前配色。换它请走 `select(_:)` —— 那里会顺手落盘。
    private(set) var theme: TerminalTheme

    /// 等宽字体族名。nil = 系统等宽（`NSFont.monospacedSystemFont`）。
    private(set) var fontFamily: String?

    /// 字号。默认 12 的来历见 `IslandTheme.terminalFont` 上面那段（量用户截图量出来的）。
    private(set) var fontSize: CGFloat

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        self.theme = preferences.terminalTheme ?? .notchDefault
        self.fontFamily = preferences.terminalFontFamily
        self.fontSize = preferences.terminalFontSize ?? IslandTheme.terminalFont.pointSize
    }

    /// 按当前字体族与字号算出来的字体。
    ///
    /// 字体族取不到时**退回系统等宽**，不退回系统默认字体：终端里非等宽会让
    /// Claude Code 的表格和 diff 直接错位，那比字体不对严重得多。
    var font: NSFont {
        guard let fontFamily,
              let font = NSFont(name: fontFamily, size: fontSize), font.isFixedPitch else {
            return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        return font
    }

    // MARK: - 改

    func select(_ theme: TerminalTheme) {
        guard theme.isValid else { return }
        self.theme = theme
        preferences.terminalTheme = theme
    }

    func selectFontFamily(_ family: String?) {
        fontFamily = family
        preferences.terminalFontFamily = family
    }

    func selectFontSize(_ size: CGFloat) {
        fontSize = size
        preferences.terminalFontSize = size
    }

    /// 读一个外部配色文件并立即生效。失败时不动现有主题。
    @discardableResult
    func importTheme(contentsOf url: URL) -> Result<TerminalTheme, TerminalThemeImport.Failure> {
        let result = TerminalThemeImport.load(contentsOf: url)
        if case .success(let theme) = result, theme.isValid {
            select(theme)
        }
        return result
    }

    // MARK: - 装进终端

    /// 把配色与字体装进一个终端视图。
    ///
    /// **背景故意不设**（保持 `.clear`）：底色由 `PanelCard` 画，终端自己填的话
    /// 四个角就方了。这条约束比主题更早，见 `TerminalPane.style` 上面那段。
    func apply(to terminal: TerminalView) {
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.caretColor = theme.cursor.nsColor
        terminal.font = font
        if theme.isValid {
            terminal.installColors(theme.ansi.map(\.terminalColor))
        }
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = .clear
    }

    /// 系统里能拿来当终端字体的那些族，给菜单用。
    ///
    /// 两道过滤：
    ///
    /// 1. **`isFixedPitch`** —— 非等宽的进了终端就是错位（SwiftTerm 按固定格宽排字，
    ///    宽字符会撑出格子、窄的留白，Claude Code 的表格和方框直接散架）。
    /// 2. **不覆盖 CJK** —— 用户 2026-08-06 点名要删的四个（BIZ UDGothic、
    ///    BIZ UDMincho、Lantinghei TC、PCMyungjo）全是 CJK 字体。它们
    ///    `isFixedPitch` 为真只是因为**汉字/假名/谚文本来就是全角等宽**，
    ///    拉丁部分并不是给终端用的。写死一张黑名单只能挡住这台机器上的这四个；
    ///    按「盖不盖汉字」判是条规则，换台机器装了别的 CJK 字体照样挡得住。
    ///
    /// 实测这条规则在这台机器上正好切出那四个（`ThemeStoreFontTests` 钉着）：
    /// 留下 Andale Mono、Courier New、Menlo、Monaco、PT Mono，加上「系统等宽」。
    ///
    /// 岛上的中文不受影响 —— 终端里的 CJK 一直是走系统字体回退画的，
    /// 不需要正文字体自己带汉字。
    static func availableMonospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12), font.isFixedPitch else { return false }
            return !coversCJK(font)
        }.sorted()
    }

    /// 这个字体带不带汉字 / 谚文 / 假名。
    static func coversCJK(_ font: NSFont) -> Bool {
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        // 汉字、谚文、平假名各取一个代表字。
        return ["\u{4E00}", "\u{AC00}", "\u{3042}"].contains { scalar in
            scalar.unicodeScalars.allSatisfy(set.contains)
        }
    }
}
