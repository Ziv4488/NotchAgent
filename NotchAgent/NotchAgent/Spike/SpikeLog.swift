//
//  SpikeLog.swift
//  探针阶段的文件日志，写到 /tmp/spike-b.log。
//  目的：不依赖人肉转述，直接看事件流判断哪一环没成立。
//  抛弃型代码，第 0.6 步会删除。
//

import AppKit

enum SpikeLog {
    static let path = "/tmp/spike-b.log"

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func reset() {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        write("=== 探针 B 日志开始 ===")
    }

    static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 监听送到本 app 的按键事件。收不到 = 键根本没进来；收到但终端没反应 = 责任链问题。
    static func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let fr = NSApp.keyWindow?.firstResponder
            write("""
            按键 keyCode=\(event.keyCode) chars=\(event.characters?.debugDescription ?? "nil") \
            appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.title.debugDescription ?? "nil") \
            firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")
            """)
            return event
        }
    }
}
