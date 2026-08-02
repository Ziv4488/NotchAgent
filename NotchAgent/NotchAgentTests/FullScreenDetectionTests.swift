//
//  FullScreenDetectionTests.swift
//  NotchAgentTests
//
//  「这个窗口是不是全屏」的几何判据。
//  这里错一次的后果是：要么最大化窗口时岛莫名消失，要么全屏时岛压在内容上。
//

import Testing
import CoreGraphics
@testable import NotchAgent

/// **这一套原来全是我照着「全屏会盖住菜单栏」这个想当然写的，五条全绿，
/// 而真机上判据一次都没成立过。** 2026-08-02 拿一个真的 `toggleFullScreen`
/// 窗口量了一遍，下面每个数字都是抄回来的，不是编的：
///
/// | 状态 | 那个窗口的 bounds | `visibleFrame` |
/// |---|---|---|
/// | 普通最大化 | `0,33 1512x901` | `(0,48,1512,901)` |
/// | 真全屏 | `0,33 1512x949` | `(0,0,1512,949)` |
///
/// 刘海机上全屏**也不盖**菜单栏那 33pt。区分点在下沿：全屏吃掉 Dock 那一条，
/// 最大化吃不掉。用户那张「全屏了岛还在上面」的截图就是这么来的。
@MainActor
struct FullScreenDetectionTests {

    /// MacBook Pro 14"：1512×982，菜单栏 33pt（CG 坐标里量出来的那一条）。
    private let screen = CGSize(width: 1512, height: 982)
    private let menuBar: CGFloat = 33

    private func isFullScreen(_ rect: CGRect) -> Bool {
        IslandWindowController.isFullScreenBounds(rect, screenSize: screen, menuBarHeight: menuBar)
    }

    /// **实机抄来的那一行。** 这条要是红了，说明又退回「全屏得顶到 y=0」的想当然。
    @Test("刘海机上的真全屏：0,33 1512x949")
    func realFullScreenOnANotchedMac() {
        #expect(isFullScreen(CGRect(x: 0, y: 33, width: 1512, height: 949)))
    }

    /// 无刘海屏上全屏是真的顶到上沿的，那条路也得留着。
    @Test("无刘海屏上的全屏：顶到 y=0，铺满整块屏幕")
    func fullScreenWithoutANotch() {
        #expect(IslandWindowController.isFullScreenBounds(
            CGRect(x: 0, y: 0, width: 1512, height: 982), screenSize: screen, menuBarHeight: 24))
    }

    /// **另一半同样要紧**：用户一把窗口最大化岛就消失，比全屏时不消失更烦人。
    @Test("普通最大化不算全屏 —— 它吃不掉 Dock 那一条")
    func maximizedIsNotFullScreen() {
        // 实机抄来的：Dock 在下面，最大化窗口停在它上面。
        #expect(!isFullScreen(CGRect(x: 0, y: 33, width: 1512, height: 901)))
        // Dock 自动隐藏时窗口能长一点，但还差热区那 4pt。
        #expect(!isFullScreen(CGRect(x: 0, y: 33, width: 1512, height: 945)))
    }

    /// Dock 摆左右两侧时，最大化窗口的**宽度**不够 —— 从这一条漏不过去。
    @Test("侧边 Dock 下的最大化：高度够了但宽度不够")
    func maximizedWithASideDock() {
        #expect(!isFullScreen(CGRect(x: 64, y: 33, width: 1448, height: 949)))
    }

    @Test("普通窗口不算全屏")
    func regularWindowIsNotFullScreen() {
        #expect(!isFullScreen(CGRect(x: 200, y: 100, width: 900, height: 600)))
    }

    /// 全屏 app 自己那条工具栏/标题栏也是 layer 0、也满宽，但它很矮 ——
    /// 实机上抓到过 `0,33 1512x32`。只看宽度和顶边的话会把它也判成全屏。
    @Test("全屏窗口自带的那条满宽标题栏不算全屏")
    func theFullScreenTitleBarIsNotTheWindow() {
        #expect(!isFullScreen(CGRect(x: 0, y: 33, width: 1512, height: 32)))
    }

    @Test("宽差一点就不算 —— 只放行 1pt 的取整误差")
    func nearlyFullScreenIsRejected() {
        #expect(isFullScreen(CGRect(x: 0, y: 33, width: 1511, height: 949)))
        #expect(!isFullScreen(CGRect(x: 0, y: 33, width: 1508, height: 949)))
    }

    @Test("比屏幕还大的窗口算全屏")
    func oversizedCountsAsFullScreen() {
        #expect(isFullScreen(CGRect(x: -2, y: -2, width: 1516, height: 986)))
    }
}
