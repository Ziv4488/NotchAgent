//
//  Preferences.swift
//  NotchAgent
//
//  持久化（spec 7）：小设置进 UserDefaults，tab 骨架进 Application Support 的 JSON。
//

import Foundation

enum HoverBehavior: String, CaseIterable {
    case highlight
    case none
}

/// 零散偏好。展开尺寸放这里而不是 tab 文件里 —— 它是「岛」的属性，不是某个会话的。
struct Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let claudePath = "claudeExecutablePath"
        static let expandedWidth = "expandedWidth"
        static let expandedContentHeight = "expandedContentHeight"
        static let contentHeightReclaimedUsageBar = "contentHeightReclaimedUsageBar"
        static let terminalThemeName = "terminalThemeName"
        static let terminalThemeCustom = "terminalThemeCustom"
        static let terminalFontFamily = "terminalFontFamily"
        static let terminalFontSize = "terminalFontSize"
        static let hoverBehavior = "hoverBehavior"
    }

    /// 用量条拆掉后留在 chrome 里的那 22pt，2026-08-02 挪回了内容区
    /// （见 `IslandMetrics.expandedChromeHeight`）。**存过的高度得跟着加回来**，
    /// 否则口径一换，已经拖过尺寸的岛会当场矮 22pt —— 用户没动过任何东西，
    /// 岛却变了，那是纯粹的回归。只补一次，补完记个标记。
    static let usageBarReclaim: CGFloat = 22

    /// 用户手填的 `claude` 绝对路径。自动找得到时是 nil。
    var claudePath: String? {
        get { defaults.string(forKey: Key.claudePath) }
        nonmutating set { defaults.set(newValue, forKey: Key.claudePath) }
    }

    /// 拖拽调整过的展开尺寸。没存过时返回 nil，让调用方用默认值。
    ///
    /// 读的时候顺手做一次口径迁移（见 `usageBarReclaim`）。放在 getter 里而不是
    /// 单独一个 `migrate()`：迁移必须发生在**任何人读到这个值之前**，
    /// 而唯一的读口就是这里 —— 少一个必须被记得调用的步骤。
    var expandedSize: (width: CGFloat, contentHeight: CGFloat)? {
        get {
            let width = defaults.double(forKey: Key.expandedWidth)
            var height = defaults.double(forKey: Key.expandedContentHeight)
            guard width > 0, height > 0 else { return nil }
            if !defaults.bool(forKey: Key.contentHeightReclaimedUsageBar) {
                height += Double(Self.usageBarReclaim)
                defaults.set(height, forKey: Key.expandedContentHeight)
                defaults.set(true, forKey: Key.contentHeightReclaimedUsageBar)
            }
            return (CGFloat(width), CGFloat(height))
        }
        nonmutating set {
            defaults.set(newValue?.width ?? 0, forKey: Key.expandedWidth)
            defaults.set(newValue?.contentHeight ?? 0, forKey: Key.expandedContentHeight)
            // 刚存进去的已经是新口径了，别让下一次读再给它加一遍 22。
            defaults.set(true, forKey: Key.contentHeightReclaimedUsageBar)
        }
    }

    /// 当前终端配色。没存过时返回 nil，让调用方用默认主题。
    ///
    /// **内置主题只存名字，导入的才存整份。** 存名字的好处是以后改内置预设的色值时，
    /// 已经选了它的用户跟着变；整份存下来的话那次改动对老用户是不生效的
    /// —— 而他看到的主题名和别人的一样，却长得不一样，没有哪个是对的。
    /// 导入来的主题没有这个问题：它本来就只存在于这台机器上。
    var terminalTheme: TerminalTheme? {
        get {
            if let name = defaults.string(forKey: Key.terminalThemeName),
               let builtin = TerminalTheme.builtin(named: name) {
                return builtin
            }
            guard let data = defaults.data(forKey: Key.terminalThemeCustom),
                  let theme = try? JSONDecoder().decode(TerminalTheme.self, from: data),
                  theme.isValid else { return nil }
            return theme
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.terminalThemeName)
                defaults.removeObject(forKey: Key.terminalThemeCustom)
                return
            }
            // **比的是整份，不是名字。** 用户完全可能导入一个也叫 Dracula 的文件
            // （`dracula.itermcolors` 存盘就叫这个名），只按名字判会把他导入的
            // 那份直接换成我们内置的那份 —— 主题名对得上、颜色却不是他要的。
            if TerminalTheme.builtin(named: newValue.name) == newValue {
                defaults.set(newValue.name, forKey: Key.terminalThemeName)
                defaults.removeObject(forKey: Key.terminalThemeCustom)
            } else {
                // 名字键必须清掉，否则下次读先命中内置那份。
                defaults.removeObject(forKey: Key.terminalThemeName)
                defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.terminalThemeCustom)
            }
        }
    }

    /// 等宽字体族名。nil = 系统等宽。
    var terminalFontFamily: String? {
        get { defaults.string(forKey: Key.terminalFontFamily) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.terminalFontFamily) }
            else { defaults.removeObject(forKey: Key.terminalFontFamily) }
        }
    }

    /// 终端字号。没存过时返回 nil。
    var terminalFontSize: CGFloat? {
        get {
            let size = defaults.double(forKey: Key.terminalFontSize)
            return size > 0 ? CGFloat(size) : nil
        }
        nonmutating set { defaults.set(newValue.map(Double.init) ?? 0, forKey: Key.terminalFontSize) }
    }

    var hoverBehavior: HoverBehavior {
        get {
            guard let raw = defaults.string(forKey: Key.hoverBehavior),
                  let value = HoverBehavior(rawValue: raw) else { return .highlight }
            return value
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.hoverBehavior) }
    }
}

/// 重启后要恢复的一个 tab。
///
/// **只存骨架，不存会话内容**（spec 7）：内容归 `~/.claude` 管，
/// 岛复制一份的话，两边一旦不一致就没有哪个是对的。
struct TabSnapshot: Codable, Equatable {
    var id: UUID
    var title: String
    var directory: String?
    /// Claude Code 的 session id，用来 `--resume`。
    var claudeSessionID: String?
}

enum TabStore {
    static var fileURL: URL {
        HookBridge.supportDirectory.appending(path: "tabs.json")
    }

    static func load(from url: URL = fileURL) -> [TabSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([TabSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    static func save(_ snapshots: [TabSnapshot], to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
