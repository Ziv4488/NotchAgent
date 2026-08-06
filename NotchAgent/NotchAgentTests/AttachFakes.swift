//
//  AttachFakes.swift
//  NotchAgentTests
//
//  贴附那几个套件共用的假 AX。真机上没法让 ChatGPT 按需卡住五秒、
//  也没法让它在第三次轮询时才长出窗口，而这两条恰恰是最容易写错的地方。
//

import CoreGraphics
import Foundation
@testable import NotchAgent

// MARK: - 假的 AX 桥

final class FakeWindow: AXWindowHandle {
    let id: Int
    init(_ id: Int) { self.id = id }
}

/// 一个能按剧本演的 AX。
///
/// 真机上没法让 ChatGPT 按需卡住五秒、也没法让它在第三次轮询时才长出窗口，
/// 而这两条恰恰是贴附最容易写错的地方。
final class FakeAX: AXBridging {
    var isTrusted = true
    var running: Set<String> = []
    /// bundleID → 当前前台窗口。nil 表示「app 在跑但还没有窗口」。
    var focused: [String: FakeWindow] = [:]
    var frames: [Int: CGRect] = [:]
    /// 窗口的最小尺寸，模拟 AX 的钳制（ChatGPT 是 480×600）。
    var minimumSize: CGSize = .zero
    /// 还要被问几次 `focusedWindow` 才把窗口交出来。模拟 app 启动中。
    var windowAppearsAfter = 0

    private(set) var launched: [String] = []
    private(set) var activated: [String] = []
    private(set) var hidden: [String] = []
    private(set) var setFrameCalls = 0
    private var focusedAsks = 0

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func launch(bundleID: String) { launched.append(bundleID); running.insert(bundleID) }
    func activate(bundleID: String) { activated.append(bundleID) }
    func hide(bundleID: String) { hidden.append(bundleID) }
    func unhide(bundleID: String) {}

    func focusedWindow(bundleID: String) -> AXWindowHandle? {
        guard running.contains(bundleID) else { return nil }
        focusedAsks += 1
        guard focusedAsks > windowAppearsAfter else { return nil }
        return focused[bundleID]
    }

    func isSameWindow(_ a: AXWindowHandle, _ b: AXWindowHandle) -> Bool {
        guard let a = a as? FakeWindow, let b = b as? FakeWindow else { return false }
        return a.id == b.id
    }

    func frame(of window: AXWindowHandle) -> CGRect? {
        guard let window = window as? FakeWindow else { return nil }
        return frames[window.id]
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of window: AXWindowHandle) -> CGRect? {
        guard let window = window as? FakeWindow else { return nil }
        setFrameCalls += 1
        // AX 只钳尺寸，位置照设 —— 跟 spec 11.4 实测一致。
        let clamped = CGRect(x: frame.minX, y: frame.minY,
                             width: max(frame.width, minimumSize.width),
                             height: max(frame.height, minimumSize.height))
        frames[window.id] = clamped
        return clamped
    }

    /// 造一个在跑、有窗口、窗口在 `frame` 的 app。
    func stage(_ bundleID: String, window id: Int, at frame: CGRect) -> FakeWindow {
        let window = FakeWindow(id)
        running.insert(bundleID)
        focused[bundleID] = window
        frames[id] = frame
        return window
    }
}

