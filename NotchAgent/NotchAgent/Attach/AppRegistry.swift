//
//  AppRegistry.swift
//  NotchAgent
//
//  从一个 `.app` 认出它是谁（plan 3.1）。
//

import AppKit

/// 一个可以贴进岛里的 app。
struct AttachableApp: Equatable {
    let bundleID: String
    /// 显示名。优先 `CFBundleDisplayName`，退回 `CFBundleName`，再退回文件名。
    let name: String
}

/// **不硬编 bundle id**（spec 6.1）：用户拖进来什么就认什么，
/// 内置那几个预设走的是完全相同的代码路径。
enum AppRegistry {

    /// 从一个文件 URL 认出 app。不是 `.app`、或者读不出 bundle id 就返回 nil。
    ///
    /// 用 `Bundle(url:)` 而不是自己去解 `Contents/Info.plist`：别名、符号链接、
    /// 以及 `.app` 里嵌套的 helper，AppKit 那套判定比我们手写的靠谱。
    static func identify(_ url: URL) -> AttachableApp? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else { return nil }

        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AttachableApp(bundleID: bundleID, name: name)
    }

    /// 一次拖进来好几个的情形：挨个认，认不出的丢掉，**同一个 app 只留一次**。
    ///
    /// 去重按 bundle id 而不是按 URL：`/Applications/ChatGPT.app` 和用户
    /// 桌面上那个别名指的是同一个 app，建两个 tab 只会让两个 tab 抢同一个窗口。
    static func identify(_ urls: [URL]) -> [AttachableApp] {
        var seen: Set<String> = []
        return urls.compactMap(identify).filter { seen.insert($0.bundleID).inserted }
    }
}
