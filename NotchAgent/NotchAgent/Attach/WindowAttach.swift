//
//  WindowAttach.swift
//  NotchAgent
//
//  把第三方 app 的真实窗口挪到岛下面，并且**保证还得回去**（spec 6.2/6.3）。
//

import AppKit
import Foundation
import OSLog

/// 贴附这条路上会出的岔子。
enum AttachFailure: Error, Equatable {
    /// 没有辅助功能授权。**这一条不算错误**，是要引导用户去开（spec 6.4）。
    case needsPermission
    /// app 没跑，也拉不起来。
    case notRunning
    /// app 跑着，但一个窗口都拿不到（还在启动、或者全最小化了）。
    case noWindow
    /// AX 调用超时 —— 目标 app 卡住了。
    case timedOut
}

/// 一个被岛接管的窗口，以及**它原来在哪**。
///
/// `original` 是这整个第 3 阶段最要紧的一个字段：spec 6.3 把「还原原始 frame」
/// 定成硬性要求，因为挪的是**别人的**窗口，岛只是暂借。
struct Attachment: Codable, Equatable {
    let bundleID: String
    /// 接管那一刻窗口的 frame，还原时设回去。
    let original: CGRect
    /// 上一次实际设成的样子（AX 钳制之后的**实得**值，不是我们要求的值）。
    var achieved: CGRect
}

/// **故意不是 `@MainActor`。** 它每个方法都可能阻塞几百毫秒（spec 11.4 撞到过
/// 一次 520ms 的 `AXSize`），放主线程上就是岛自己卡住。队列与合并由
/// `AttachDriver` 管，这里只保证「在同一条队列上被串行调用」时是对的。
final class WindowAttach {
    private let ax: AXBridging
    private let log = Logger(subsystem: "com.notchagent", category: "attach")

    /// 单次贴附动作的上限。超过就当目标 app 卡住了，报 `.timedOut`。
    ///
    /// 比 `SystemAXBridge.messagingTimeout`（单次往返 1 秒）宽：一次 attach 里
    /// 有「拉起 app + 等窗口出现 + 读原 frame + 设新 frame」好几趟。
    var deadline: TimeInterval = 5

    /// 等目标 app 的窗口冒出来时，隔多久看一眼。
    var pollInterval: TimeInterval = 0.1

    /// 测试注入假时钟，好让超时那条路不用真的等五秒。
    var now: () -> Date = Date.init
    /// 测试注入空实现，免得单测真的睡。
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// 账本：**每个窗口一份**，不是每个 tab 一份。
    ///
    /// 用户在 app 里 ⌘` 换窗口时岛要跟着换贴附对象（08-06 定的形态），
    /// 被换下去的那个必须当场还原 —— 否则他切回去会发现窗口尺寸被我们改过，
    /// 而那时岛根本没在管它了，再也没人还得回来。
    private var ledger: [(window: AXWindowHandle, attachment: Attachment)] = []

    /// 账本变了就喊一声。**这条线是给「岛崩了怎么办」用的**：
    /// spec 6.3 把还原定成硬性要求，可 `applicationWillTerminate` 只覆盖正常退出。
    /// 被强杀、崩溃、断电时，用户的窗口就永远卡在岛给的尺寸上了 ——
    /// 除非原始 frame 在磁盘上另有一份，下次启动照着还。
    var ledgerDidChange: (([Attachment]) -> Void)?

    init(ax: AXBridging = SystemAXBridge()) {
        self.ax = ax
    }

    private func ledgerChanged() { ledgerDidChange?(ledger.map(\.attachment)) }

    /// 认领上一轮没还回去的窗口。**尽力而为**：窗口句柄跨不了进程，
    /// 只能按 bundle id 找到那个 app 现在的前台窗口摆回去。单窗口 app
    /// （ChatGPT、Claude 桌面版）这就是对的；多窗口的可能还错人，
    /// 但「还错一个窗口」也比「有个窗口永远卡在那儿」强。
    func reclaim(_ loans: [Attachment]) {
        guard ax.isTrusted else { return }
        for loan in loans {
            guard ax.isRunning(bundleID: loan.bundleID),
                  let window = ax.focusedWindow(bundleID: loan.bundleID) else { continue }
            ax.setFrame(loan.original, of: window)
            log.info("清账：\(loan.bundleID, privacy: .public) 还回 \(loan.original.debugDescription, privacy: .public)")
        }
    }

    var attachedCount: Int { ledger.count }

    func attachment(for window: AXWindowHandle) -> Attachment? {
        ledger.first { ax.isSameWindow($0.window, window) }?.attachment
    }

    // MARK: - 接管

    /// 把 `bundleID` 的前台窗口挪到 `rect`。
    ///
    /// 返回**实得**的 frame：目标窗口有最小尺寸，压不下去时 AX 会钳制，
    /// 而最小尺寸问不出来（spec 11.4），只能设完读回。岛拿这个值反过来
    /// 钉住自己的拖拽下限。
    @discardableResult
    func attach(bundleID: String, to rect: CGRect) -> Result<CGRect, AttachFailure> {
        guard ax.isTrusted else { return .failure(.needsPermission) }

        let started = now()
        if !ax.isRunning(bundleID: bundleID) {
            ax.launch(bundleID: bundleID)
        }

        // 等不到窗口只有两种可能：app 压根没起来，或者起来了但窗口迟迟不出现。
        // 前者是「你没装 / 拉不起来」，后者是「它卡住了」，给用户看的话不一样。
        guard let window = waitForWindow(bundleID: bundleID, since: started) else {
            return .failure(ax.isRunning(bundleID: bundleID) ? .timedOut : .notRunning)
        }

        // 换了窗口就把上一个还回去。**先还再接**：反过来的话，两个窗口之间
        // 切来切去时账本会先长后缩，中间那一下如果崩了就有窗口留在岛底下。
        releaseOthers(of: bundleID, keeping: window)

        if attachment(for: window) == nil {
            guard let original = ax.frame(of: window) else { return .failure(.noWindow) }
            ledger.append((window, Attachment(bundleID: bundleID,
                                              original: original,
                                              achieved: original)))
            log.info("接管 \(bundleID, privacy: .public) 的窗口，原 frame \(original.debugDescription, privacy: .public)")
            ledgerChanged()
        }

        guard let achieved = ax.setFrame(rect, of: window) else { return .failure(.noWindow) }
        record(achieved: achieved, for: window)
        ax.activate(bundleID: bundleID)
        return .success(achieved)
    }

    /// 拖拽时逐帧调这个。**只设 frame，不碰账本里的 `original`。**
    ///
    /// spec 11.4 实测 60fps 灌得动、零拖尾，所以这里不做降级；
    /// 但调用方必须把它放到后台队列上并且合并积压（`AXSize` 撞到过 520ms，
    /// 落在主线程上就是岛自己卡半秒）。
    @discardableResult
    func follow(_ rect: CGRect, bundleID: String) -> CGRect? {
        guard let entry = ledger.last(where: { $0.attachment.bundleID == bundleID }) else { return nil }
        guard let achieved = ax.setFrame(rect, of: entry.window) else { return nil }
        record(achieved: achieved, for: entry.window)
        return achieved
    }

    // MARK: - 交还

    /// 把某个 app 的窗口还回原位，并从账本里划掉。
    @discardableResult
    func restore(bundleID: String) -> Bool {
        let mine = ledger.filter { $0.attachment.bundleID == bundleID }
        guard !mine.isEmpty else { return false }
        for entry in mine { put(back: entry) }
        ledger.removeAll { $0.attachment.bundleID == bundleID }
        ledgerChanged()
        return true
    }

    /// 全部还回去。退出前必走 —— 挪的是别人的窗口。
    func restoreAll() {
        for entry in ledger { put(back: entry) }
        ledger.removeAll()
        ledgerChanged()
    }

    func hide(bundleID: String) { ax.hide(bundleID: bundleID) }
    func unhide(bundleID: String) { ax.unhide(bundleID: bundleID) }

    // MARK: -

    private func put(back entry: (window: AXWindowHandle, attachment: Attachment)) {
        ax.setFrame(entry.attachment.original, of: entry.window)
        log.info("交还 \(entry.attachment.bundleID, privacy: .public) 到 \(entry.attachment.original.debugDescription, privacy: .public)")
    }

    /// 同一个 app 换了窗口 —— 把不再贴附的那些当场还回去。
    private func releaseOthers(of bundleID: String, keeping window: AXWindowHandle) {
        let stale = ledger.filter {
            $0.attachment.bundleID == bundleID && !ax.isSameWindow($0.window, window)
        }
        for entry in stale { put(back: entry) }
        ledger.removeAll {
            $0.attachment.bundleID == bundleID && !ax.isSameWindow($0.window, window)
        }
    }

    private func record(achieved: CGRect, for window: AXWindowHandle) {
        guard let index = ledger.firstIndex(where: { ax.isSameWindow($0.window, window) }) else { return }
        ledger[index].attachment.achieved = achieved
    }

    /// app 刚被拉起来时窗口还没有，隔一会儿看一眼，直到超时。
    private func waitForWindow(bundleID: String, since started: Date) -> AXWindowHandle? {
        while true {
            if let window = ax.focusedWindow(bundleID: bundleID) { return window }
            if expired(since: started) { return nil }
            sleep(pollInterval)
        }
    }

    private func expired(since started: Date) -> Bool {
        now().timeIntervalSince(started) >= deadline
    }
}
