//
//  TerminalSelectionPixelTests.swift
//  NotchAgentTests
//
//  选区的高亮，画面上到底还在不在 —— 用像素说话。
//

import AppKit
import SwiftTerm
import Testing
@testable import NotchAgent

/// **第一套「看得见」的测试。**
///
/// 岛里绝大部分手测行是「盯着看」：高亮消没消、黑边多宽、两条弧平不平行。
/// 这类事以前只能人去看，因为断言的是**画面**不是状态。做法是把视图真的
/// 渲染进一张位图（`cacheDisplay(in:to:)` 会走完整的 `draw(_:)`），然后数像素。
///
/// 起因是用户 2026-08-02 报的：⌘A 之后点一下，高亮还留在屏幕上。
/// 状态层查过了是干净的（`selectionActive == false`、`getSelection() == nil`），
/// 所以只剩「画面没刷新」这一种可能 —— 那就得由画面来回答。
/// 这套跑下来是绿的，说明**终端视图这一层没问题**，问题在岛的事件路径上。
@Suite("终端选区的像素")
@MainActor
struct TerminalSelectionPixelTests {

    /// 和生产里 `TerminalPane.style` 一模一样：透明底 + layer-backed。
    ///
    /// 这两样是有嫌疑的 —— 透明底意味着「用背景色填一遍」擦不掉任何东西，
    /// layer-backed 又可能让旧内容留在层里。所以测的时候必须照抄，
    /// 换成不透明黑底就把要查的东西查没了。
    private func terminal() -> ObservingTerminalView {
        let view = ObservingTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = IslandTheme.terminalForeground
        view.font = IslandTheme.terminalFont
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.feed(text: "alpha beta gamma\r\ndelta epsilon zeta\r\n")
        return view
    }

    /// 画面上有多少像素不是全透明的。高亮铺满整屏时这个数会大一个量级。
    private func litPixels(_ view: NSView) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        // 隔行隔列采样：够灵敏（高亮是一大片），又比逐像素快得多。
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { count += 1 }
            }
        }
        return count
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    @Test("⌘A 会在画面上点亮一大片")
    func selectAllLightsUpTheScreen() {
        let view = terminal()
        let plain = litPixels(view)
        view.selectAll()
        #expect(litPixels(view) > plain * 10, "全选的高亮应该是一大片，不是几个字")
    }

    /// **用户报的那条（10.11f 的 A 解释）。**
    /// 单击之后画面必须回到没选区的样子 —— 一个像素都不该多。
    @Test("单击之后，⌘A 的高亮从画面上消失")
    func clickingClearsTheHighlightOnScreen() {
        let view = terminal()
        let plain = litPixels(view)
        view.selectAll()
        #expect(litPixels(view) > plain)

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50)))

        #expect(litPixels(view) == plain, "高亮还留在画面上")
    }

    /// 按下去手指动了一两个点（触控板上几乎必然）时走的是另一条路：
    /// SwiftTerm 会当成一次极短的拖选。那也不该留下上一次的整屏高亮。
    @Test("带抖动的单击也不留下旧高亮", arguments: [CGFloat(1), 10])
    func jitteryClickAlsoClearsIt(jitter: CGFloat) {
        let view = terminal()
        let plain = litPixels(view)
        view.selectAll()

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50 + jitter, y: 50)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50 + jitter, y: 50)))

        // 极短的拖选最多点亮一个格子，绝不该还是整屏。
        #expect(litPixels(view) < plain + 200)
    }
}

/// §10.8：终端右边**不许留一条竖着的空条**。
///
/// SwiftTerm 无条件给 `NSScroller` 留位置（`reservedScrollerWidth`），
/// 包里没人去藏它。岛里那条滚动条既没人看也没人拖，白占一列 ——
/// `ObservingTerminalView` 在 `init` 里把它藏掉，`reservedScrollerWidth`
/// 于是变成 0，同样宽度下能多排两列。
///
/// 这条既查「藏了没有」，也查**画面上正文真的排到了右边**。
@Suite("终端右边那条内沿")
@MainActor
struct TerminalScrollerTests {

    private let size = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test("滚动条藏掉了，同样宽度能多排几列")
    func hidingTheScrollerReclaimsColumns() throws {
        // **必须真的走一次尺寸变化。** `reservedScrollerWidth` 是在布局时算进
        // 可用宽度的，`init` 之后直接问 `cols`，两边都还是按初始 frame 算出来的
        // 那个数（实测都是 45），看不出差别。先小后大，逼它重排一次。
        let ours = ObservingTerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        let stock = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        ours.frame = size
        stock.frame = size

        let ourScrollers = ours.subviews.compactMap { $0 as? NSScroller }
        #expect(!ourScrollers.isEmpty, "SwiftTerm 不再自带 NSScroller 了，这条得重写")
        #expect(ourScrollers.allSatisfy { $0.isHidden }, "滚动条没藏住")
        #expect(stock.subviews.contains { $0 is NSScroller && !$0.isHidden },
                "原版本来就没有可见的滚动条，那这条测试没有意义")
        #expect(ours.getTerminal().cols > stock.getTerminal().cols,
                "藏了滚动条却没多出列来：\(ours.getTerminal().cols) vs \(stock.getTerminal().cols)")
    }

    /// 画面上的复核：把一整行填满，最右边那几个点必须亮着。
    @Test("正文一直排到右边框，右边不留空条")
    func textReachesTheRightEdge() {
        let view = ObservingTerminalView(frame: size)
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = IslandTheme.terminalForeground
        view.font = IslandTheme.terminalFont
        view.wantsLayer = true
        view.feed(text: String(repeating: "#", count: 200))

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("拿不到位图"); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        var rightmost = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    rightmost = max(rightmost, x)
                    break
                }
            }
        }
        // 滚动条那 15pt 要是还占着位置，最右边的字会停在 385 上下。
        #expect(rightmost > rep.pixelsWide - 12,
                "正文只排到 \(rightmost)，右边空了 \(rep.pixelsWide - rightmost)pt")
    }
}
