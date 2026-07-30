//
//  ProjectDirectory.swift
//  NotchAgent
//
//  从 ~/.claude/projects/ 还原出用过的项目目录（spec 3.3）。
//

import Foundation

struct ProjectDirectory: Identifiable, Equatable {
    var path: String
    /// 该项目最近一次会话的时间，用来排序。
    var lastUsed: Date
    /// 有历史会话记录，可以 `claude --resume`。
    var hasSessions: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// 显示用的短路径：家目录换成 ~。
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum ProjectDirectoryStore {
    static var projectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects")
    }

    /// 最近用过的项目，按最后使用时间倒序。
    static func recent(limit: Int = 8, root: URL? = nil) -> [ProjectDirectory] {
        let root = root ?? projectsRoot
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [ProjectDirectory] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let transcripts = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == "jsonl" } ?? []

            guard let path = resolvePath(for: entry, transcripts: transcripts) else { continue }

            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            found.append(ProjectDirectory(path: path, lastUsed: modified, hasSessions: !transcripts.isEmpty))
        }

        return Array(found.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }

    /// 目录名把 `/` 换成了 `-`，而路径本身也可能带 `-`，反解是有歧义的。
    /// 所以优先从会话记录里直接读 `cwd`，那是确切值；读不到才退回猜。
    static func resolvePath(for directory: URL, transcripts: [URL]) -> String? {
        if let cwd = cwdFromTranscripts(transcripts) { return cwd }
        return decodeDirectoryName(directory.lastPathComponent)
    }

    private static func cwdFromTranscripts(_ transcripts: [URL]) -> String? {
        let newest = transcripts.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in newest.prefix(2) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // 只读头部，会话记录可能很大。
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  let text = String(data: chunk, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
                return cwd
            }
        }
        return nil
    }

    /// 兜底猜测：`-Users-ziv-Desktop-Foo` → `/Users/ziv/Desktop/Foo`。
    /// 名字里本来就有 `-` 的会猜错，所以逐段验证存在性，走不通就整段还原成一个带 `-` 的名字。
    static func decodeDirectoryName(_ name: String) -> String? {
        let segments = name.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return nil }

        let fm = FileManager.default
        var path = ""
        var index = 0
        while index < segments.count {
            var candidate = path + "/" + segments[index]
            var consumed = index
            // 当前段拼不出存在的路径时，往后并入更多段，把被拆开的 `-` 接回去。
            while !fm.fileExists(atPath: candidate), consumed + 1 < segments.count {
                consumed += 1
                candidate += "-" + segments[consumed]
            }
            guard fm.fileExists(atPath: candidate) else { return nil }
            path = candidate
            index = consumed + 1
        }
        return path.isEmpty ? nil : path
    }
}
