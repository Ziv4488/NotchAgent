//
//  SpikeWindowLevels.swift
//  探针 B 的补充 —— 采样屏幕上各窗口的层级，用来查出输入法候选框窗口的层级，
//  从而决定岛的窗口层级该设在哪一档。
//  抛弃型代码，第 0.6 步会删除。
//

import AppKit

enum SpikeWindowLevels {

    /// 采样 seconds 秒，每 300ms 记录一次层级 ≥ 18 的所有屏上窗口。
    /// 采样期间请持续用输入法打字，让候选框保持显示。
    static func sample(seconds: Double = 10) {
        SpikeLog.write("=== 开始采样窗口层级，\(Int(seconds)) 秒，请持续用输入法打字 ===")
        var seen = Set<String>()
        var elapsed = 0.0
        let interval = 0.3

        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            elapsed += interval
            for line in snapshot() where !seen.contains(line) {
                seen.insert(line)
                SpikeLog.write("  " + line)
            }
            if elapsed >= seconds {
                timer.invalidate()
                SpikeLog.write("=== 采样结束，共 \(seen.count) 个不同窗口 ===")
            }
        }
    }

    private static func snapshot() -> [String] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return ["(取不到窗口列表)"]
        }

        return list.compactMap { info in
            let level = info[kCGWindowLayer as String] as? Int ?? 0
            guard level >= 18 else { return nil }

            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            var box = ""
            if let b = info[kCGWindowBounds as String] as? [String: Any],
               let w = b["Width"] as? Double, let h = b["Height"] as? Double,
               let x = b["X"] as? Double, let y = b["Y"] as? Double {
                box = " @(\(Int(x)),\(Int(y))) \(Int(w))×\(Int(h))"
            }
            return "层级 \(level)  \(owner)\(box)"
        }
    }
}
