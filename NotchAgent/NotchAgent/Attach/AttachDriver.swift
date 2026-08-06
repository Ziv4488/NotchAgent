//
//  AttachDriver.swift
//  NotchAgent
//
//  把 `WindowAttach` 挪到后台队列上，并且**把拖拽时积压的帧合并掉**。
//

import AppKit
import Foundation

/// 岛这边唯一会碰的贴附入口。
///
/// **存在的理由只有一个：AX 不能放在主线程上。** spec 11.4 实测单次调用中位数
/// 只有几毫秒，但 p95 到 9.7ms、`AXSize` 撞到过一次 520ms —— 而 60fps 的预算是
/// 16.7ms。落在主线程上，用户拖着岛的边框，岛自己会卡住半秒。
///
/// 另一半职责是**合并**：拖拽每帧都会喂一个新矩形进来，而 AX 一次只做得了一个。
/// 排队的话手松开了窗口还在追之前的帧。这里只留「最新的那一个」，中间的直接丢
/// —— 反正没人看得见被跳过的中间态。
@MainActor
final class AttachDriver {
    private let core: WindowAttach

    /// 干活的地方。
    ///
    /// 生产是一条串行后台队列，`done` 回到主线程；单测塞个同步执行的，
    /// 好一步步断言。抽成闭包而不是直接写 `DispatchQueue`，是为了让
    /// 「合并」那段逻辑能离线测 —— 它才是这个类里唯一容易写错的地方。
    var perform: (@escaping () -> Void, @escaping () -> Void) -> Void

    /// 欠账落在哪。单测指到临时文件上去，别写用户真的那份。
    var ledgerURL: URL = AttachLedgerStore.fileURL

    init(core: WindowAttach = WindowAttach()) {
        self.core = core
        let queue = DispatchQueue(label: "com.notchagent.attach", qos: .userInteractive)
        self.perform = { work, done in
            queue.async {
                work()
                DispatchQueue.main.async(execute: done)
            }
        }
        core.ledgerDidChange = { [weak self] loans in
            guard let self else { return }
            AttachLedgerStore.save(loans, to: self.ledgerURL)
        }
    }

    /// 上一轮没还回去的窗口，启动时清一次账。
    func reclaimOutstanding() {
        let loans = AttachLedgerStore.load(from: ledgerURL)
        guard !loans.isEmpty else { return }
        perform({ [core] in core.reclaim(loans) },
                { [ledgerURL] in AttachLedgerStore.save([], to: ledgerURL) })
    }

    // MARK: - 接管

    /// 接管 `bundleID` 的前台窗口，摆到 `rect`（**AppKit 坐标，原点左下**）。
    ///
    /// 交回来的是**实得** frame，同样是 AppKit 坐标。岛拿它反过来钉自己的
    /// 拖拽下限 —— 目标窗口的最小尺寸问不出来，只能设完读回（spec 11.4）。
    func attach(bundleID: String, to rect: CGRect,
                completion: @escaping (Result<CGRect, AttachFailure>) -> Void) {
        var result: Result<CGRect, AttachFailure>?
        perform({ [core] in
            result = core.attach(bundleID: bundleID, to: AXCoordinates.topLeft(rect))
        }, {
            completion(result?.map { AXCoordinates.bottomLeft($0) } ?? .failure(.noWindow))
        })
    }

    // MARK: - 拖拽时跟随

    private var pending: [String: CGRect] = [:]
    private var inFlight: Set<String> = []

    /// 拖拽每帧调。**同一个 app 只有最新那一帧会真的落到 AX 上。**
    func follow(_ rect: CGRect, bundleID: String) {
        pending[bundleID] = rect
        guard !inFlight.contains(bundleID) else { return }
        pump(bundleID)
    }

    private func pump(_ bundleID: String) {
        guard let rect = pending.removeValue(forKey: bundleID) else {
            inFlight.remove(bundleID)
            return
        }
        inFlight.insert(bundleID)
        perform({ [core] in
            core.follow(AXCoordinates.topLeft(rect), bundleID: bundleID)
        }, { [weak self] in
            self?.pump(bundleID)
        })
    }

    /// 还没落地的那一帧被丢了没有。收起岛时用 —— 别让一帧迟到的 follow
    /// 把已经藏起来的窗口又拽回屏幕上。
    func cancelPendingFollows() { pending.removeAll() }

    // MARK: - 交还

    func restore(bundleID: String, completion: (() -> Void)? = nil) {
        pending[bundleID] = nil
        perform({ [core] in core.restore(bundleID: bundleID) },
                { completion?() })
    }

    /// 全部还回去。**退出前这一下是同步的** —— 异步派出去的话，
    /// app 在队列跑到之前就没了，用户的窗口永远留在岛底下（spec 6.3）。
    func restoreAllSynchronously() {
        pending.removeAll()
        core.restoreAll()
    }

    func hide(bundleID: String) {
        perform({ [core] in core.hide(bundleID: bundleID) }, {})
    }

    func unhide(bundleID: String) {
        perform({ [core] in core.unhide(bundleID: bundleID) }, {})
    }

    var attachedCount: Int { core.attachedCount }
}
