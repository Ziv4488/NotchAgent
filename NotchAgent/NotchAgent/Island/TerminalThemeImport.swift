//
//  TerminalThemeImport.swift
//  NotchAgent
//
//  把 iTerm / Ghostty 的配色文件读成 `TerminalTheme`（plan「4.3 的范围」）。
//

import Foundation

/// 导入外部配色文件。
///
/// **失败一律返回 nil，不做部分导入。** 一套读了一半的配色比不导入更糟：
/// 用户看到主题名换了、颜色只变了几个，会以为是 app 坏了而不是文件不对。
enum TerminalThemeImport {
    enum Failure: Error, Equatable {
        case unreadable
        /// 认得出格式，但缺色或色值坏了。
        case incomplete(String)
        case unknownFormat
    }

    /// 支持的扩展名，给 `NSOpenPanel` 用。Ghostty 的主题文件**没有扩展名**
    /// （`~/.config/ghostty/themes/` 底下就是裸文件名），所以面板不能只按后缀过滤。
    static let itermExtension = "itermcolors"

    static func load(contentsOf url: URL) -> Result<TerminalTheme, Failure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        let name = url.deletingPathExtension().lastPathComponent

        if url.pathExtension.lowercased() == Self.itermExtension {
            return iterm(data, name: name)
        }
        // 没有后缀或后缀不认识时按 Ghostty 的 key = value 试一次。
        // 先试 iTerm 是因为它是 plist，判得准；不是 plist 才轮到文本格式。
        if let theme = try? iterm(data, name: name).get() {
            return .success(theme)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unknownFormat) }
        return ghostty(text, name: name)
    }

    // MARK: - iTerm2 `.itermcolors`

    /// XML plist，每个颜色是一个 dict，分量是 0...1 的 Double。
    ///
    /// 键名形如 `Ansi 0 Color` … `Ansi 15 Color`，外加
    /// `Background Color` / `Foreground Color` / `Cursor Color`。
    ///
    /// **分量可能超出 0...1**：iTerm 存的是 P3 或者线性值时会有 1.02 这种，
    /// `RGB` 的 init 会夹回去。夹掉总比整份拒收好 —— 那是一个还原得出来的颜色。
    private static func iterm(_ data: Data, name: String) -> Result<TerminalTheme, Failure> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            return .failure(.unknownFormat)
        }

        func color(_ key: String) -> TerminalTheme.RGB? {
            guard let entry = root[key] as? [String: Any],
                  let red = entry["Red Component"] as? Double,
                  let green = entry["Green Component"] as? Double,
                  let blue = entry["Blue Component"] as? Double else { return nil }
            return TerminalTheme.RGB(red: red, green: green, blue: blue)
        }

        var ansi: [TerminalTheme.RGB] = []
        for index in 0..<16 {
            guard let value = color("Ansi \(index) Color") else {
                return .failure(.incomplete("缺少 Ansi \(index) Color"))
            }
            ansi.append(value)
        }
        guard let background = color("Background Color") else {
            return .failure(.incomplete("缺少 Background Color"))
        }
        guard let foreground = color("Foreground Color") else {
            return .failure(.incomplete("缺少 Foreground Color"))
        }
        // 光标色可以缺 —— 不少配色只给前景背景。缺了就跟前景走，
        // 这也是真终端的常见默认。
        let cursor = color("Cursor Color") ?? foreground

        return .success(TerminalTheme(name: name, background: background,
                                      foreground: foreground, cursor: cursor, ansi: ansi))
    }

    // MARK: - Ghostty 主题文件

    /// 文本格式，每行 `key = value`，`#` 起头是注释：
    ///
    /// ```
    /// palette = 0=#1d1f21
    /// background = 1d1f21
    /// foreground = c5c8c6
    /// cursor-color = c5c8c6
    /// ```
    ///
    /// 色值带不带 `#` 都算数（Ghostty 自己两种都收）。
    private static func ghostty(_ text: String, name: String) -> Result<TerminalTheme, Failure> {
        var palette: [Int: TerminalTheme.RGB] = [:]
        var background: TerminalTheme.RGB?
        var foreground: TerminalTheme.RGB?
        var cursor: TerminalTheme.RGB?
        var sawAnyKey = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "palette":
                // 值本身还是 `<index>=<hex>`。
                guard let inner = value.firstIndex(of: "=") else { continue }
                let indexText = value[value.startIndex..<inner].trimmingCharacters(in: .whitespaces)
                let hex = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
                guard let index = Int(indexText), (0..<16).contains(index),
                      let color = TerminalTheme.RGB(hex: hex) else { continue }
                palette[index] = color
                sawAnyKey = true
            case "background":
                background = TerminalTheme.RGB(hex: value)
                sawAnyKey = true
            case "foreground":
                foreground = TerminalTheme.RGB(hex: value)
                sawAnyKey = true
            case "cursor-color":
                cursor = TerminalTheme.RGB(hex: value)
                sawAnyKey = true
            default:
                continue
            }
        }

        guard sawAnyKey else { return .failure(.unknownFormat) }

        var ansi: [TerminalTheme.RGB] = []
        for index in 0..<16 {
            guard let color = palette[index] else {
                return .failure(.incomplete("缺少 palette = \(index)"))
            }
            ansi.append(color)
        }
        guard let background else { return .failure(.incomplete("缺少 background")) }
        guard let foreground else { return .failure(.incomplete("缺少 foreground")) }

        return .success(TerminalTheme(name: name, background: background,
                                      foreground: foreground,
                                      cursor: cursor ?? foreground, ansi: ansi))
    }
}
