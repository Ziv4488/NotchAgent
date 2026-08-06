//
//  AttachLedgerStore.swift
//  NotchAgent
//
//  「还欠着谁一个窗口」的账，落在磁盘上。
//

import Foundation

/// spec 6.3 把「还原原始 frame」定成硬性要求，但 `applicationWillTerminate`
/// **只覆盖正常退出**。岛崩了、被活动监视器强杀、断电 —— 这几种情况下用户的
/// ChatGPT 就永远卡在岛给的那个尺寸上了，而且岛下次起来根本不知道自己欠着账。
///
/// 所以账要落盘：接管时写一笔，还回去时划掉，下次启动先清上一轮的余账。
///
/// **存的是 AX 坐标**（原点左上）—— 账本里的 `original` 本来就是从 AX 读的，
/// 清账时也直接喂回 AX，中间不经过 AppKit 那套坐标，就没有翻转出错的机会。
enum AttachLedgerStore {
    static var fileURL: URL {
        HookBridge.supportDirectory.appending(path: "attached-windows.json")
    }

    static func load(from url: URL = fileURL) -> [Attachment] {
        guard let data = try? Data(contentsOf: url),
              let loans = try? JSONDecoder().decode([Attachment].self, from: data) else {
            return []
        }
        return loans
    }

    static func save(_ loans: [Attachment], to url: URL = fileURL) {
        // 空账本就把文件删掉，别留一个 `[]` 让人以为还欠着什么。
        guard !loans.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(loans) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
