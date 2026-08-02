//
//  TabStripScrollTests.swift
//  NotchAgentTests
//
//  tab 多到装不下时，还得够得着。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// **这一套是用来顶掉手测 §13.17–13.19 的。**
///
/// 那三行原本要求：开十几个 tab、两指横扫、再切到一个滚出去的 tab 看它回不回来 ——
/// 每改一次 tab 条就得重来一遍。这里把它们做成断言：SwiftUI 的
/// `ScrollView` 在 macOS 上落成一个真的 `NSScrollView`（`HostingScrollView`），
/// 它的 `documentView` 宽度和 `contentView.bounds.origin` 就是「能不能滚」和
/// 「滚到哪儿了」的直接证据。
///
/// 改之前 tab 条是个裸 `HStack`：画到岛的边界就被切掉，后面的 tab 连同末尾的 ＋
/// 一起够不着，一个 tab 都关不掉。把 `ScrollView` 拿掉这三条会立刻红
/// —— 找不到 `NSScrollView`。
@Suite("tab 条装不下的时候")
@MainActor
struct TabStripScrollTests {

    /// 岛在 14" 上展开的默认宽度。tab 条能用的就这么宽。
    private let viewportWidth: CGFloat = 560

    /// 把 tab 条真的挂到一个窗口上跑起来。
    ///
    /// **必须有真窗口。** 离屏的 `NSHostingView` 里 `documentView` 的 frame 是
    /// 0×0，`ScrollViewReader` 的 `scrollTo` 也不会发生 —— 量出来的东西全是假的。
    private func mount(tabs: Int) async throws -> (IslandModel, NSWindow, NSScrollView) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        for index in 1...tabs { model.debugStartSession(named: "会话-\(index)") }
        model.selectTab(model.tabs[0].id)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: viewportWidth, height: 34),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TabStrip(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: viewportWidth, height: 34)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle(0.3)

        // 找不到就是「tab 条不再是可滚的」——**这正是要防的回归**。
        // 用 #require 而不是 fatalError：后者会把整个测试进程带走，
        // 一条断言失败变成「整轮测试崩了」，看不出是哪儿的问题。
        let scroll = try #require(Self.scrollView(in: hosting),
                                  "tab 条里没有 NSScrollView —— 溢出的 tab 就够不着了")
        return (model, window, scroll)
    }

    /// 等 AppKit 把布局和滚动动画走完。
    ///
    /// **切成小片、每片之间 `await Task.yield()`。** 一口气
    /// `RunLoop.run(until: +0.8)` 会把主线程独占 0.8 秒 —— 别的 `@MainActor`
    /// 测试正 `await` 着的续体全排不上号。实测把 `CLISessionTests` 里那条
    /// 「resize 之后 stty 报新列数」直接搞红了：它 sleep 200ms 之后才发 resize，
    /// 而那 200ms 被我们占着，等轮到它时子进程早就把旧尺寸打印完了。
    private func settle(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = scrollView(in: sub) { return scroll }
        }
        return nil
    }

    /// §13.17：十几个 tab 时内容确实比可视区宽，而且**装在滚动视图里**。
    @Test("tab 多到装不下时，内容能滚")
    func overflowingStripScrolls() async throws {
        let (model, window, scroll) = try await mount(tabs: 14)
        defer { window.orderOut(nil) }

        let content = try #require(scroll.documentView?.frame.width)
        #expect(content > viewportWidth, "14 个 tab 应该撑爆 560pt")
        #expect(model.tabStripWidth > viewportWidth)
        // 能滚多远 = 内容宽 − 可视宽。是正数才谈得上「够得着最后一个」。
        #expect(content - scroll.contentView.bounds.width > 0)
    }

    /// §13.18：切到一个已经滚出视野的 tab，tab 条要把它带回来。
    ///
    /// 不带回来的话岛看着毫无反应 —— 内容区换了，但高亮的那个在屏幕外。
    @Test("切到滚出去的 tab，会自动滚过去")
    func selectingAHiddenTabScrollsItIntoView() async throws {
        let (model, window, scroll) = try await mount(tabs: 14)
        defer { window.orderOut(nil) }

        let atFirst = scroll.contentView.bounds.origin.x
        model.selectTab(model.tabs[13].id)
        await settle(0.8)
        let atLast = scroll.contentView.bounds.origin.x
        #expect(atLast > atFirst, "选最后一个 tab 之后应该滚过去了")

        // 再切回第一个，也得滚回来。
        model.selectTab(model.tabs[0].id)
        await settle(0.8)
        #expect(scroll.contentView.bounds.origin.x < atLast)
    }

    /// §13.19：只有两三个 tab 时内容装得下，不该出现可滚的余量
    /// （`scrollBounceBehavior(.basedOnSize)` 保证的就是这个 —— 装得下就不晃）。
    @Test("tab 少的时候没有可滚的余量")
    func shortStripDoesNotScroll() async throws {
        let (_, window, scroll) = try await mount(tabs: 3)
        defer { window.orderOut(nil) }

        let content = try #require(scroll.documentView?.frame.width)
        #expect(content <= scroll.contentView.bounds.width + 1)
    }
}
