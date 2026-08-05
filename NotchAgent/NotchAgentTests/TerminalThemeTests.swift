//
//  TerminalThemeTests.swift
//  NotchAgentTests
//
//  终端配色与导入（plan 4.3）。
//

import AppKit
import SwiftUI
import Testing
// `terminalColor` 返回的是 SwiftTerm 的 Color，读它的分量要这个 import。
import SwiftTerm
@testable import NotchAgent

@Suite("终端主题")
struct TerminalThemeTests {

    // MARK: - 预设本身

    @Test("三组内置预设都是完整的 16 色")
    func builtinsAreComplete() {
        #expect(TerminalTheme.builtins.count == 3)
        for theme in TerminalTheme.builtins {
            #expect(theme.ansi.count == 16, "\(theme.name) 的 ANSI 不是 16 色")
            #expect(theme.isValid, "\(theme.name) 装不进终端")
        }
    }

    /// **这条守的是「默认那一档一个像素都不变」。**
    ///
    /// 4.3 之前终端从来没设过调色板，走的是 SwiftTerm 自带的默认 ——
    /// 而它的默认是 `Color.terminalAppColors`（macOS 终端 app 那套）。
    /// 现在我们开始主动 `installColors` 了，默认主题装进去的必须还是那 16 个值，
    /// 否则老用户什么都没动，颜色却变了。
    ///
    /// 那 16 个值在 SwiftTerm 里是 internal，取不到，所以这里也只能抄一份对着比 ——
    /// 抄的源头是 `Sources/SwiftTerm/Colors.swift` 的 `terminalAppColors`。
    @Test("默认主题的 ANSI 16 色 = SwiftTerm 原本的默认（macOS 终端 app 那套）")
    func defaultPaletteMatchesWhatWeUsedToRender() {
        let terminalAppColors = [
            "000000", "C23621", "25BC24", "ADAD27",
            "492EE1", "D338D3", "33BBC8", "CBCCCD",
            "818383", "FC391F", "31E722", "EAEC23",
            "5833FF", "F935F8", "14F0F0", "E9EBEB",
        ]
        for (index, hex) in terminalAppColors.enumerated() {
            #expect(TerminalTheme.notchDefault.ansi[index] == TerminalTheme.RGB(hex: hex),
                    "第 \(index) 号色和 SwiftTerm 的默认对不上")
        }
    }

    @Test("默认主题的背景就是内容区那块 #1E1E1E")
    func defaultBackgroundIsTheEstablishedCharcoal() {
        #expect(TerminalTheme.notchDefault.background == TerminalTheme.RGB(hex: "1E1E1E"))
    }

    @Test("每组预设的正文对自己的背景都读得清")
    func everyBuiltinIsReadable() throws {
        for theme in TerminalTheme.builtins {
            let ratio = contrastRatio(theme.foreground.nsColor, on: theme.background.nsColor)
            #expect(ratio >= 7, "\(theme.name) 的对比度只有 \(ratio)")
        }
    }

    // 原来这儿有一条「每组预设的背景都是深色」，依据是 plan 4.3 那句
    // 「浅色岛配黑刘海视觉上是破的」。用户 2026-08-05 要了浅色主题，那条就作废了。
    //
    // 我当时顺手换成了一条「主题再怎么换岛体都是纯黑」—— **那条是假的**：
    // 它循环遍历三组主题，断言却是 `IslandTheme.edgeLine == .black`，
    // 和循环变量毫无关系，把主题全删了它也绿。已经删掉。
    //
    // 岛体是 `IslandShell.swift:124` 的 `.fill(.black)`，一个字面量，
    // 主题这条路根本够不着它；外沿那三层另有 `IslandPixelTests` 的
    // 「岛的外沿是三层」在守。这里不需要第三条。

    /// 有了浅色主题之后，卡片上那些文字不能再写死白色。
    @Test("浅底主题上的墨色翻成黑的，深底仍是白的")
    func inkFollowsTheBackground() {
        #expect(TerminalTheme.oneLight.prefersDarkInk)
        #expect(!TerminalTheme.notchDefault.prefersDarkInk)
        #expect(!TerminalTheme.dracula.prefersDarkInk)
    }

    /// `brightnessComponent` 是 HSB 的 B，只看最大分量 —— 纯黄在它眼里和纯白一样亮。
    /// 判「底是深是浅」必须用相对亮度，不然一套黄底主题会被判成深色，
    /// 墨色仍是白的，正文当场看不见。
    @Test("深浅的判据是相对亮度，不是 HSB 的明度")
    func lightnessUsesRelativeLuminance() {
        var yellow = TerminalTheme.notchDefault
        yellow.background = TerminalTheme.RGB(hex: "FFFF00")!
        #expect(yellow.background.nsColor.brightnessComponent == 1)   // HSB 说它顶亮
        #expect(yellow.prefersDarkInk)                                 // 相对亮度也说亮 —— 该翻黑
    }

    // MARK: - 字体列表

    /// 用户 2026-08-06：「先删掉 biz 两个，lantinghei，PCMyungjo，共四个」。
    ///
    /// **不是写死一张黑名单。** 这四个的共同点是它们都是 CJK 字体 ——
    /// `isFixedPitch` 为真只因为汉字/假名/谚文本来就是全角等宽，拉丁部分
    /// 并不是给终端用的。按「盖不盖汉字」判，换台机器装了别的 CJK 字体照样挡得住。
    @Test("菜单里不列 CJK 字体")
    func cjkFamiliesAreExcluded() {
        let families = ThemeStore.availableMonospacedFamilies()
        for unwanted in ["BIZ UDGothic", "BIZ UDMincho", "Lantinghei TC", "PCMyungjo"] {
            #expect(!families.contains(unwanted), "\(unwanted) 不该出现在字体菜单里")
        }
    }

    /// 反过来也得成立 —— 规则不能宽到把真正的终端字体也筛掉。
    @Test("常见的终端等宽字体还在")
    func realTerminalFamiliesSurvive() {
        let families = ThemeStore.availableMonospacedFamilies()
        // Menlo 和 Monaco 是 macOS 自带的，任何一台机器上都有。
        #expect(families.contains("Menlo"))
        #expect(families.contains("Monaco"))
        #expect(!families.isEmpty)
    }

    @Test("判据本身：CJK 字体认得出，纯拉丁等宽认不成 CJK")
    func cjkDetection() throws {
        // 这台机器上有的才测，换台机器没装也不该红。
        if let biz = NSFont(name: "BIZ UDGothic", size: 12) {
            #expect(ThemeStore.coversCJK(biz))
        }
        #expect(!ThemeStore.coversCJK(try #require(NSFont(name: "Menlo", size: 12))))
        #expect(!ThemeStore.coversCJK(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
    }

    // MARK: - RGB

    @Test("十六进制带不带 # 都认，坏值一律不认")
    func hexParsing() {
        #expect(TerminalTheme.RGB(hex: "#FF8000") == TerminalTheme.RGB(hex: "ff8000"))
        #expect(TerminalTheme.RGB(hex: "FFFFFF") == TerminalTheme.RGB(red: 1, green: 1, blue: 1))
        #expect(TerminalTheme.RGB(hex: "1E1E1E")?.red == 30.0 / 255)
        #expect(TerminalTheme.RGB(hex: "FFF") == nil)
        #expect(TerminalTheme.RGB(hex: "GGGGGG") == nil)
        #expect(TerminalTheme.RGB(hex: "") == nil)
    }

    @Test("超出 0...1 的分量夹回去，不溢出")
    func componentsAreClamped() {
        let color = TerminalTheme.RGB(red: 1.4, green: -0.2, blue: 0.5)
        #expect(color.red == 1)
        #expect(color.green == 0)
        // UInt16 转换会在越界时崩，所以夹回去这件事必须发生在这之前。
        #expect(color.terminalColor.red == 65535)
        #expect(color.terminalColor.green == 0)
    }

    // MARK: - 导入

    @Test("读得出 iTerm 的 .itermcolors")
    func importsItermColors() throws {
        let url = try write(itermPlist(), named: "Sample.itermcolors")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let theme = try TerminalThemeImport.load(contentsOf: url).get()
        #expect(theme.name == "Sample")
        #expect(theme.isValid)
        #expect(theme.background == TerminalTheme.RGB(red: 0, green: 0, blue: 0))
        #expect(theme.ansi[1] == TerminalTheme.RGB(red: 1, green: 0, blue: 0))
    }

    @Test("读得出 Ghostty 的主题文件（没有扩展名也行）")
    func importsGhosttyTheme() throws {
        let url = try write(Data(ghosttyTheme().utf8), named: "tokyonight")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let theme = try TerminalThemeImport.load(contentsOf: url).get()
        #expect(theme.name == "tokyonight")
        #expect(theme.isValid)
        #expect(theme.background == TerminalTheme.RGB(hex: "1a1b26"))
        #expect(theme.foreground == TerminalTheme.RGB(hex: "c0caf5"))
        #expect(theme.ansi[0] == TerminalTheme.RGB(hex: "15161e"))
        #expect(theme.ansi[15] == TerminalTheme.RGB(hex: "c0caf5"))
    }

    /// 缺色不能当成「导入成功了但有几个色是黑的」——
    /// 那样用户看到的是一套坏掉的配色，而 app 说它成功了。
    @Test("缺色的文件整份拒收，并说清缺的是哪一个")
    func rejectsIncompleteThemes() throws {
        var text = ghosttyTheme()
        text = text.replacingOccurrences(of: "palette = 7=#a9b1d6\n", with: "")
        let url = try write(Data(text.utf8), named: "broken")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = TerminalThemeImport.load(contentsOf: url)
        #expect(result == .failure(.incomplete("缺少 palette = 7")))
    }

    @Test("既不是 plist 也不是 key = value 的文件报「不认识的格式」")
    func rejectsUnknownFormat() throws {
        let url = try write(Data("这不是配色文件\n随便几行字\n".utf8), named: "notes.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(TerminalThemeImport.load(contentsOf: url) == .failure(.unknownFormat))
    }

    @Test("光标色可以缺，缺了跟前景走")
    func cursorFallsBackToForeground() throws {
        var text = ghosttyTheme()
        text = text.replacingOccurrences(of: "cursor-color = #c0caf5\n", with: "")
        let url = try write(Data(text.utf8), named: "nocursor")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let theme = try TerminalThemeImport.load(contentsOf: url).get()
        #expect(theme.cursor == theme.foreground)
    }

    // MARK: - 持久化

    @Test("内置主题只存名字，改了预设色值老用户跟着变")
    func builtinsPersistByName() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-builtin-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let preferences = Preferences(defaults: defaults)

        preferences.terminalTheme = .dracula
        #expect(defaults.string(forKey: "terminalThemeName") == "Dracula")
        #expect(defaults.data(forKey: "terminalThemeCustom") == nil)
        #expect(preferences.terminalTheme == .dracula)
    }

    /// **回归**：导入一个也叫 Dracula 的文件，不能被内置那份顶掉。
    /// 只按名字判存法的话，用户导入的颜色会在下一次读取时无声地变成我们的。
    @Test("导入的主题跟内置重名时，存的还是导入的那份")
    func importedThemeSurvivesNameCollision() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-collision-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let preferences = Preferences(defaults: defaults)

        var impostor = TerminalTheme.oneLight
        impostor.name = "Dracula"          // 跟内置同名，颜色是另一套
        preferences.terminalTheme = impostor

        #expect(defaults.string(forKey: "terminalThemeName") == nil)
        #expect(preferences.terminalTheme == impostor)
        #expect(preferences.terminalTheme != .dracula)
    }

    @Test("没存过时返回 nil，让调用方用默认主题")
    func absentThemeReadsAsNil() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-empty-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        #expect(Preferences(defaults: defaults).terminalTheme == nil)
    }

    @Test("字体族与字号存得下、读得回")
    func fontPreferencesRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-font-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let preferences = Preferences(defaults: defaults)

        #expect(preferences.terminalFontFamily == nil)
        #expect(preferences.terminalFontSize == nil)

        preferences.terminalFontFamily = "Menlo"
        preferences.terminalFontSize = 14
        #expect(preferences.terminalFontFamily == "Menlo")
        #expect(preferences.terminalFontSize == 14)

        preferences.terminalFontFamily = nil
        #expect(preferences.terminalFontFamily == nil)
    }

    // MARK: - ThemeStore

    @Test("选主题会落盘，重开一个 store 还在")
    func storeRemembersSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-store-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let preferences = Preferences(defaults: defaults)

        let store = ThemeStore(preferences: preferences)
        #expect(store.theme == .notchDefault)
        store.select(.oneLight)
        #expect(ThemeStore(preferences: preferences).theme == .oneLight)
    }

    /// 不满 16 色的主题装进 SwiftTerm 是**静默无效**的（`installColors` 对长度
    /// 不是 16 的数组直接 return）。所以得在更早的地方拦下来。
    @Test("残缺的主题选不进去")
    func storeRejectsInvalidTheme() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-invalid-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let store = ThemeStore(preferences: Preferences(defaults: defaults))

        var broken = TerminalTheme.dracula
        broken.ansi.removeLast()
        store.select(broken)
        #expect(store.theme == .notchDefault)
    }

    /// 字体族取不到、或者取到一个非等宽的，都得退回系统等宽 ——
    /// 终端里非等宽会让 Claude Code 的表格和 diff 当场错位。
    @Test("字体族无效时退回系统等宽，不退回系统默认字体")
    func fontFallsBackToMonospaced() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-fallback-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let store = ThemeStore(preferences: Preferences(defaults: defaults))

        store.selectFontFamily("这个字体不存在")
        #expect(store.font.isFixedPitch)

        store.selectFontFamily("Helvetica")     // 存在，但不是等宽
        #expect(store.font.isFixedPitch)
    }

    @Test("字号跟着设置走")
    func fontSizeFollowsPreference() throws {
        let defaults = try #require(UserDefaults(suiteName: "theme-size-\(UUID())"))
        defer { defaults.removeSuite(named: defaults.description) }
        let store = ThemeStore(preferences: Preferences(defaults: defaults))

        #expect(store.fontSize == IslandTheme.terminalFont.pointSize)
        store.selectFontSize(15)
        #expect(store.font.pointSize == 15)
    }

    // MARK: - 夹具

    /// **文件名就是主题名**（`TerminalThemeImport` 拿去掉扩展名的最后一段），
    /// 所以这里不能靠给文件名加前缀来去重 —— 那会连主题名一起改掉。
    /// 每次单独开一个目录。
    private func write(_ data: Data, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func itermPlist() -> Data {
        var entries = ""
        for index in 0..<16 {
            let value = Double(index) / 15
            entries += component("Ansi \(index) Color", red: index == 1 ? 1 : value,
                                 green: index == 1 ? 0 : value, blue: index == 1 ? 0 : value)
        }
        entries += component("Background Color", red: 0, green: 0, blue: 0)
        entries += component("Foreground Color", red: 1, green: 1, blue: 1)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entries)</dict>
        </plist>
        """
        return Data(plist.utf8)
    }

    private func component(_ key: String, red: Double, green: Double, blue: Double) -> String {
        """
        <key>\(key)</key>
        <dict>
        <key>Red Component</key><real>\(red)</real>
        <key>Green Component</key><real>\(green)</real>
        <key>Blue Component</key><real>\(blue)</real>
        </dict>

        """
    }

    private func ghosttyTheme() -> String {
        """
        # Tokyo Night
        palette = 0=#15161e
        palette = 1=#f7768e
        palette = 2=#9ece6a
        palette = 3=#e0af68
        palette = 4=#7aa2f7
        palette = 5=#bb9af7
        palette = 6=#7dcfff
        palette = 7=#a9b1d6
        palette = 8=#414868
        palette = 9=#f7768e
        palette = 10=#9ece6a
        palette = 11=#e0af68
        palette = 12=#7aa2f7
        palette = 13=#bb9af7
        palette = 14=#7dcfff
        palette = 15=#c0caf5
        background = #1a1b26
        foreground = #c0caf5
        cursor-color = #c0caf5

        """
    }

    private func contrastRatio(_ a: NSColor, on b: NSColor) -> Double {
        let first = luminance(a), second = luminance(b)
        let lighter = max(first, second), darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }
}
