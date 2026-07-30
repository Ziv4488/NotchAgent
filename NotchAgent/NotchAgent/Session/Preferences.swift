//
//  Preferences.swift
//  NotchAgent
//
//  持久化（spec 7）：小设置进 UserDefaults，tab 骨架进 Application Support 的 JSON。
//

import Foundation

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
    }

    /// 用户手填的 `claude` 绝对路径。自动找得到时是 nil。
    var claudePath: String? {
        get { defaults.string(forKey: Key.claudePath) }
        nonmutating set { defaults.set(newValue, forKey: Key.claudePath) }
    }

    /// 拖拽调整过的展开尺寸。没存过时返回 nil，让调用方用默认值。
    var expandedSize: (width: CGFloat, contentHeight: CGFloat)? {
        get {
            let width = defaults.double(forKey: Key.expandedWidth)
            let height = defaults.double(forKey: Key.expandedContentHeight)
            guard width > 0, height > 0 else { return nil }
            return (CGFloat(width), CGFloat(height))
        }
        nonmutating set {
            defaults.set(newValue?.width ?? 0, forKey: Key.expandedWidth)
            defaults.set(newValue?.contentHeight ?? 0, forKey: Key.expandedContentHeight)
        }
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
