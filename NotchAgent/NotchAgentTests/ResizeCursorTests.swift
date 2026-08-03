//
//  ResizeCursorTests.swift
//  NotchAgentTests
//
//  拖拽手柄的光标：形状对不对、会不会顺手把点击也吃了。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// **起因：用户 2026-08-03 报「出现箭头的时机和位置不稳定，好暧昧」（§8.2/8.3）。**
///
/// 查出来是两套光标机制在打架 —— 手柄用 SwiftUI 的 `.onHover` + `NSCursor.push()`，
/// 而 SwiftTerm 的 `MacTerminalView` 用 AppKit 的 `addCursorRect` 加一句
/// `NSCursor.iBeam.set()`。`.set()` 只换当前光标、不动 push 出来的栈，于是箭头
/// 一出现就被随便一次 `cursorUpdate` 顶掉，而 `.onHover` 不会再触发第二次。
///
/// 改成也用 cursor rect。**「谁赢」这件事离线测不了** —— 那要真的把鼠标挪过去，
/// 而这台机器上有人在用。这里能钉的是它前面那几步：矩形登记了没有、登记的是
/// 哪个光标、会不会顺手把点击也吃掉、热区有没有大到压住 ✕。
@Suite("拖拽手柄的光标")
@MainActor
struct ResizeCursorTests {

    private func mount(cursor: NSCursor,
                       size: CGSize = CGSize(width: 8, height: 200)) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CursorRect(cursor: cursor))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func trackingView(in view: NSView) -> CursorRect.TrackingView? {
        if let found = view as? CursorRect.TrackingView { return found }
        for sub in view.subviews {
            if let found = trackingView(in: sub) { return found }
        }
        return nil
    }

    /// 登记的矩形要盖住整块手柄 —— 少一条边，那条边上就没有箭头。
    @Test("光标矩形盖满整块手柄")
    func cursorRectCoversTheWholeHandle() throws {
        let (window, hosting) = mount(cursor: .resizeLeftRight)
        defer { window.orderOut(nil) }

        let probe = try #require(trackingView(in: hosting), "手柄里没有登记光标的那层视图")
        probe.resetCursorRects()
        let registered = try #require(probe.registered, "resetCursorRects 什么都没登记")
        #expect(registered.rect == probe.bounds)
        #expect(registered.rect.width > 0 && registered.rect.height > 0)
    }

    /// 每种手柄要的是不同的箭头，别接错线。
    @Test("要哪个光标就登记哪个", arguments: [NSCursor.resizeLeftRight, .resizeUpDown, .arrow])
    func registersTheRequestedCursor(cursor: NSCursor) throws {
        let (window, hosting) = mount(cursor: cursor)
        defer { window.orderOut(nil) }

        let probe = try #require(trackingView(in: hosting))
        probe.resetCursorRects()
        #expect(probe.registered?.cursor === cursor)
    }

    /// **这一层一个点击都不许吃。**
    ///
    /// §2.2b 踩过一次：拖拽层盖在整个岛上、没显式放行点击，把 tab 芯片和 ✕ 全挡掉了，
    /// 表现和「光标没激活」难以区分。手势仍然在 SwiftUI 那层，这层只管光标形状。
    @Test("登记光标的那层不吃点击")
    func theCursorLayerNeverSwallowsClicks() throws {
        let (window, hosting) = mount(cursor: .resizeLeftRight)
        defer { window.orderOut(nil) }

        let probe = try #require(trackingView(in: hosting))
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 4, y: 100), CGPoint(x: 7, y: 199)] {
            #expect(probe.hitTest(point) == nil, "\(point) 被这层吃掉了")
        }
    }

    /// 热区加宽到 8pt 是为了好抓，但**不能宽到压住收起用的 ✕**。
    /// 竖边就贴在状态带最右边那条线上，✕ 只留了那么点右边距。
    @Test("竖边的热区不会压到 ✕ 上")
    func theEdgeHandleLeavesTheCloseButtonAlone() {
        let thickness = ResizeHandles.Layout.edgeThickness
        let closeInset = StatusBand.Layout.closeTrailingInset
        #expect(thickness <= closeInset,
                "手柄 \(thickness)pt 宽，而 ✕ 只离右沿 \(closeInset)pt")
        // 太细就是「摸不着」，那正是这轮要修的。
        #expect(ResizeHandles.Layout.edgeThickness >= 8)
    }

    /// 竖边上沿只该空出内凹圆弧那一段。
    ///
    /// 原来空的是整个菜单栏高度（32pt），于是竖边上面一大截根本没有手柄 ——
    /// 用户报的「位置不稳定」有一半是它。
    @Test("竖边上沿只让开内凹圆弧那一小段")
    func theEdgeHandleStartsRightBelowTheInvertedCorner() {
        let model = IslandModel.previewModel(state: .expanded)
        let inset = model.cornerRadii.inverted
        #expect(inset > 0)
        #expect(inset < model.geometry.menuBarHeight,
                "让开的这一段不该有整条状态带那么高")
    }
}
