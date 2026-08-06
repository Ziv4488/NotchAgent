//
//  WindowAttachTests.swift
//  NotchAgentTests
//
//  贴附那一层。测的都是「出岔子才走到」的分支 —— 真机上造不出来（plan 3.2）。
//

import CoreGraphics   // MEMBER_IMPORT_VISIBILITY 开着，CGRect/CGSize 得自己 import
import Foundation
import Testing
@testable import NotchAgent

@Suite("贴附第三方窗口")
@MainActor
struct WindowAttachTests {

    private let islandRect = CGRect(x: 100, y: 200, width: 560, height: 342)

    private func make(_ ax: FakeAX) -> WindowAttach {
        let attach = WindowAttach(ax: ax)
        attach.sleep = { _ in }          // 单测不真的睡
        return attach
    }

    // MARK: - 还原（spec 6.3 的硬性要求）

    @Test("移除 tab 后窗口回到原始 frame")
    func restoresOriginalFrame() {
        let ax = FakeAX()
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        let window = ax.stage("com.openai.codex", window: 1, at: original)
        let attach = make(ax)

        attach.attach(bundleID: "com.openai.codex", to: islandRect)
        #expect(ax.frame(of: window) != original)   // 确实被挪走了

        #expect(attach.restore(bundleID: "com.openai.codex"))
        #expect(ax.frame(of: window) == original)
        #expect(attach.attachedCount == 0)
    }

    @Test("反复贴附不会把已经挪过的位置当成原始 frame")
    func originalFrameIsRecordedOnlyOnce() {
        let ax = FakeAX()
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        let window = ax.stage("com.openai.codex", window: 1, at: original)
        let attach = make(ax)

        attach.attach(bundleID: "com.openai.codex", to: islandRect)
        // 再贴一次（用户切走又切回来）。这一下读到的 frame 已经是岛的尺寸了，
        // 要是又记一次原始 frame，窗口就再也回不去了。
        attach.attach(bundleID: "com.openai.codex", to: CGRect(x: 0, y: 0, width: 400, height: 300))

        attach.restore(bundleID: "com.openai.codex")
        #expect(ax.frame(of: window) == original)
    }

    @Test("restoreAll 把每一个都还回去")
    func restoreAllReturnsEverything() {
        let ax = FakeAX()
        let a = ax.stage("com.a", window: 1, at: CGRect(x: 10, y: 10, width: 800, height: 600))
        let b = ax.stage("com.b", window: 2, at: CGRect(x: 20, y: 20, width: 900, height: 700))
        let attach = make(ax)

        attach.attach(bundleID: "com.a", to: islandRect)
        attach.attach(bundleID: "com.b", to: islandRect)
        #expect(attach.attachedCount == 2)

        attach.restoreAll()
        #expect(ax.frame(of: a) == CGRect(x: 10, y: 10, width: 800, height: 600))
        #expect(ax.frame(of: b) == CGRect(x: 20, y: 20, width: 900, height: 700))
        #expect(attach.attachedCount == 0)
    }

    /// 08-06 定的形态：一个 app 一个 tab，跟随它的前台窗口。
    /// 换窗口时**被换下去的那个必须当场还原** —— 岛之后不再管它，
    /// 没还的话用户 ⌘` 切回去会发现尺寸被改过，而且再也没人还得回来。
    @Test("app 内换窗口时，上一个窗口当场还原")
    func switchingWindowsReleasesThePrevious() {
        let ax = FakeAX()
        let firstOriginal = CGRect(x: 10, y: 10, width: 800, height: 600)
        let first = ax.stage("com.cursor", window: 1, at: firstOriginal)
        let attach = make(ax)
        attach.attach(bundleID: "com.cursor", to: islandRect)

        // 用户 ⌘` 切到第二个窗口。
        let secondOriginal = CGRect(x: 50, y: 50, width: 1000, height: 700)
        let second = FakeWindow(2)
        ax.focused["com.cursor"] = second
        ax.frames[2] = secondOriginal
        attach.attach(bundleID: "com.cursor", to: islandRect)

        #expect(ax.frame(of: first) == firstOriginal)      // 已经还回去了
        #expect(ax.frame(of: second) != secondOriginal)    // 新的贴上了
        #expect(attach.attachedCount == 1)

        attach.restoreAll()
        #expect(ax.frame(of: second) == secondOriginal)
    }

    // MARK: - 出岔子的路

    @Test("没授权时报 needsPermission，一个窗口都不碰")
    func withoutPermissionNothingMoves() {
        let ax = FakeAX()
        ax.isTrusted = false
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        let window = ax.stage("com.openai.codex", window: 1, at: original)
        let attach = make(ax)

        #expect(attach.attach(bundleID: "com.openai.codex", to: islandRect)
                == .failure(.needsPermission))
        #expect(ax.frame(of: window) == original)
        #expect(ax.setFrameCalls == 0)
    }

    @Test("app 没跑就先拉起来")
    func launchesWhenNotRunning() {
        let ax = FakeAX()
        let window = FakeWindow(1)
        ax.focused["com.openai.codex"] = window
        ax.frames[1] = CGRect(x: 0, y: 0, width: 800, height: 600)
        let attach = make(ax)

        #expect(attach.attach(bundleID: "com.openai.codex", to: islandRect).isSuccess)
        #expect(ax.launched == ["com.openai.codex"])
    }

    @Test("窗口晚几拍才出现也等得到")
    func waitsForTheWindowToAppear() {
        let ax = FakeAX()
        ax.windowAppearsAfter = 3      // 前三次问都还没有
        let window = FakeWindow(1)
        ax.focused["com.openai.codex"] = window
        ax.frames[1] = CGRect(x: 0, y: 0, width: 800, height: 600)
        let attach = make(ax)

        #expect(attach.attach(bundleID: "com.openai.codex", to: islandRect).isSuccess)
    }

    @Test("等窗口等过了头，报 timedOut 而不是死等")
    func givesUpAfterTheDeadline() {
        let ax = FakeAX()
        ax.running.insert("com.openai.codex")
        ax.windowAppearsAfter = .max   // 永远不出现
        let attach = make(ax)

        // 假时钟：每问一次时间就走 1 秒，5 秒的 deadline 到点就得放弃。
        var clock = Date(timeIntervalSince1970: 0)
        attach.now = {
            defer { clock += 1 }
            return clock
        }
        #expect(attach.attach(bundleID: "com.openai.codex", to: islandRect)
                == .failure(.timedOut))
    }

    // MARK: - 最小尺寸

    /// spec 11.4：窗口只暴露 AXPosition / AXSize 两个可写属性，**没有 AXMinValue**，
    /// 最小尺寸问不出来。所以 attach 得把**实得**值交出去，让岛拿它钉住拖拽下限。
    @Test("压不下去时交出实得尺寸，不是我们要求的尺寸")
    func reportsTheClampedSizeBack() throws {
        let ax = FakeAX()
        ax.minimumSize = CGSize(width: 480, height: 600)   // ChatGPT 实测值
        _ = ax.stage("com.openai.codex", window: 1, at: CGRect(x: 0, y: 0, width: 1164, height: 806))
        let attach = make(ax)

        let asked = CGRect(x: 100, y: 200, width: 420, height: 342)
        let achieved = try #require(attach.attach(bundleID: "com.openai.codex", to: asked).value)

        #expect(achieved.size == CGSize(width: 480, height: 600))
        #expect(achieved.origin == asked.origin)   // 位置照设，AX 只钳尺寸
    }

    @Test("follow 只挪窗口，不动账本里的原始 frame")
    func followDoesNotDisturbTheLedger() throws {
        let ax = FakeAX()
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        let window = ax.stage("com.openai.codex", window: 1, at: original)
        let attach = make(ax)
        attach.attach(bundleID: "com.openai.codex", to: islandRect)

        // 拖拽：连着灌很多帧。
        for width in stride(from: 560.0, through: 900.0, by: 20) {
            attach.follow(CGRect(x: 100, y: 200, width: width, height: 342),
                          bundleID: "com.openai.codex")
        }
        let ledger = try #require(attach.attachment(for: window))
        #expect(ledger.original == original)
        #expect(ledger.achieved.width == 900)

        attach.restore(bundleID: "com.openai.codex")
        #expect(ax.frame(of: window) == original)
    }
}

private extension Result where Success == CGRect, Failure == AttachFailure {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var value: CGRect? { if case .success(let rect) = self { rect } else { nil } }
}
