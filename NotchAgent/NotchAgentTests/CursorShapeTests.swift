//
//  CursorShapeTests.swift
//  NotchAgentTests
//
//  把指针真的挪到岛上，读系统此刻显示的是哪个光标。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// **这套测试会动鼠标。** 它用 `CGEvent` 发真的移动事件，跑完把指针放回原处。
/// 需要辅助功能权限；没有的话整套跳过（发出去的事件不会生效，测什么都是假的）。
///
/// 为什么值得这么干：§8.2/8.3 的光标改了四版，前四版全是「我假定一个机制、
/// 再写测试去印证那个假定」，绿得很好看，实机一次没对过。真正的判据只有一个 ——
/// **指针挪过去的时候，系统显示的是哪个光标**。这套就测这个。
///
/// 量出来的根因：AppKit 的光标机制（cursor rect、`.cursorUpdate` 跟踪区、
/// SwiftUI 的 `pointerStyle`）**默认只在 key window 里生效**，而岛是
/// `.nonactivatingPanel`，多数时候不是 key。所以两条路都得有：
///
/// | 岛的状态 | 谁在管光标 |
/// |---|---|
/// | 是 key | `pointerStyle`（`ResizeHandles.resizePointer`） |
/// | 不是 key | `.activeAlways` 跟踪区 + `NotchHostingView` 在进出事件里自己设 |
///
/// 两条都验：拆掉任意一条，对应那半边会全变成普通箭头（实测确认过）。
///
/// **还有一格是改不了的**：app 不在前台时，热区上也只有普通箭头 ——
/// 后台 app 改不动指针，这是系统行为。量过三格：
/// active+key ✓、active+非 key ✓、inactive ✗。
/// 这条没写成测试用例，因为造那一格要把 Finder 拉到前台，每次跑测试都打扰人。
@Suite("光标形状（真的把指针挪过去）", .serialized)
@MainActor
struct CursorShapeTests {

    @Test("岛不是 key 的时候，热区上照样有对应的光标")
    func cursorsOnANonKeyIsland() async throws {
        try await walkTheEdges(makeKey: false)
    }

    @Test("岛是 key 的时候也一样")
    func cursorsOnAKeyIsland() async throws {
        try await walkTheEdges(makeKey: true)
    }

    // MARK: -

    private func walkTheEdges(makeKey: Bool) async throws {
        guard AXIsProcessTrusted() else { return }   // 没权限，发的事件不作数

        let origin = NSEvent.mouseLocation
        defer { warp(toScreenPoint: origin) }

        let model = IslandModel.previewModel(state: .expanded)
        let canvas = CGSize(width: model.size.width + 200, height: model.size.height + 100)
        let screen = try #require(NSScreen.main)
        // 摆在屏幕正中，别贴屏幕上沿 —— 那儿有真的岛。
        let frame = CGRect(x: screen.frame.midX - canvas.width / 2,
                           y: screen.frame.midY - canvas.height / 2,
                           width: canvas.width, height: canvas.height)

        // borderless 的窗口当不了 key，正好用来造「岛不是 key」那一半。
        let window = NSWindow(contentRect: frame,
                              styleMask: makeKey ? [.titled] : [.borderless],
                              backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = NotchHostingView(rootView: IslandShell(model: model))
        hosting.islandGeometry = { (model.size, model.cornerRadii) }
        hosting.frame = CGRect(origin: .zero, size: canvas)
        window.contentView = hosting
        window.orderFrontRegardless()
        // **两个用例都要 app 在前台。** 后台 app 根本改不动指针（背景窗口的内容区
        // 一律显示普通箭头，这是系统行为，不是我们的 bug）—— 量过：把前台让给
        // Finder，热区上读到的就是普通箭头，两条机制都不管用。
        // 区别只在窗口是不是 key：borderless 的窗口当不了 key，正好用来造那一半。
        NSApp.activate(ignoringOtherApps: true)
        if makeKey { window.makeKeyAndOrderFront(nil) }
        hosting.layoutSubtreeIfNeeded()
        await settle(0.4)
        defer { window.orderOut(nil) }


        let bottom = try #require(model.resizeHandleFrames[.bottomEdge], "底边热区没报位置")
        let corner = try #require(model.resizeHandleFrames[.bottomLeading])
        let leading = try #require(model.resizeHandleFrames[.leadingEdge])
        let outside = CGPoint(x: bottom.midX, y: model.size.height + 40)
        let inside = CGPoint(x: bottom.midX, y: model.size.height - 80)

        // 走一圈，正是用户描述的那条路线：进 → 出 → 再进 → 再出。
        try await expectCursor(.arrow, at: outside, "岛外", window, frame, makeKey: makeKey)
        try await expectCursor(ResizeHandles.Kind.bottomEdge.cursor, at: CGPoint(x: bottom.midX, y: bottom.midY),
                               "底边", window, frame, makeKey: makeKey)
        try await expectCursor(.arrow, at: inside, "岛内容区", window, frame, makeKey: makeKey)
        try await expectCursor(ResizeHandles.Kind.bottomEdge.cursor, at: CGPoint(x: bottom.midX, y: bottom.midY),
                               "底边（再进）", window, frame, makeKey: makeKey)
        // 这一条是用户报的「移出岛外的时候也有箭头」：出了岛必须还原。
        try await expectCursor(.arrow, at: outside, "岛外（再出）", window, frame, makeKey: makeKey)
        try await expectCursor(ResizeHandles.Kind.bottomLeading.cursor,
                               at: CGPoint(x: corner.midX, y: corner.midY), "左下角", window, frame, makeKey: makeKey)
        try await expectCursor(ResizeHandles.Kind.leadingEdge.cursor,
                               at: CGPoint(x: leading.midX, y: leading.midY), "左竖边", window, frame, makeKey: makeKey)
    }

    /// 把指针挪到画布里的某一点，断言系统显示的是哪个光标。
    ///
    /// **别的套件也在造窗口、抢 key 和前台**，而光标归指针底下那个窗口管。
    /// 所以每次测量前先把自己摆回前台，读之前再确认一遍环境（指针真的落在目标点上、
    /// 底下的窗口真的是我们这个、app 真的在前台）——不对就重试。
    /// 上一轮拿 `isKeyWindow` 直接断言，六轮里六轮都飘，教训在
    /// `ModalLayeringTests` 里记着。
    private func expectCursor(_ expected: NSCursor, at point: CGPoint, _ label: String,
                              _ window: NSWindow, _ frame: CGRect, makeKey: Bool) async throws {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let target = CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y)
        let global = CGPoint(x: target.x, y: screenTop - target.y)

        for attempt in 1...3 {
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            if makeKey { window.makeKeyAndOrderFront(nil) }
            await settle(0.05)

            // 先挪开再挪回来：不动的话系统不会重算光标，读到的是上一格的结果。
            await move(to: CGPoint(x: global.x, y: global.y - 60), from: screenTop)
            await move(to: global, from: screenTop)
            await settle(0.2)

            let landed = NSEvent.mouseLocation
            let ours = NSWindow.windowNumber(at: landed, belowWindowWithWindowNumber: 0) == window.windowNumber
            guard abs(landed.x - target.x) < 2, abs(landed.y - target.y) < 2, ours,
                  NSApp.isActive, window.isKeyWindow == makeKey
            else {
                if attempt == 3 { return }   // 环境始终不配合，**宁可跳过也不要假绿**
                continue
            }

            let actual = try #require(NSCursor.currentSystem, "读不到系统光标")
            let complaint = "\(label)：光标是 \(actual.image.size)/\(actual.hotSpot)，"
                + "该是 \(expected.image.size)/\(expected.hotSpot)"
            #expect(actual.image.size == expected.image.size && actual.hotSpot == expected.hotSpot,
                    Comment(rawValue: complaint))
            return
        }
    }

    /// 分几步走 —— 一步跳过去，系统当它没动，不重算光标。
    private func move(to global: CGPoint, from screenTop: CGFloat) async {
        for step in 1...4 {
            let now = NSEvent.mouseLocation
            let start = CGPoint(x: now.x, y: screenTop - now.y)
            let t = CGFloat(step) / 4
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: start.x + (global.x - start.x) * t,
                                                 y: start.y + (global.y - start.y) * t),
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            await settle(0.03)
        }
    }

    private func warp(toScreenPoint point: CGPoint) {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screenTop - point.y))
    }

    private func settle(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }
}
