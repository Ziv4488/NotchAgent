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

@MainActor
struct FullScreenDetectionTests {

    private let screen = CGSize(width: 1512, height: 982)

    private func isFullScreen(_ rect: CGRect) -> Bool {
        IslandWindowController.isFullScreenBounds(rect, screenSize: screen)
    }

    @Test("真全屏：顶到上沿且铺满整块屏幕")
    func trueFullScreen() {
        #expect(isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 982)))
    }

    @Test("普通最大化不算全屏 —— 它盖不住菜单栏")
    func maximizedIsNotFullScreen() {
        // 菜单栏 32pt，最大化的窗口从它下面开始。
        #expect(!isFullScreen(CGRect(x: 0, y: 32, width: 1512, height: 950)))
        // 就算高度够，只要没顶到上沿就不是全屏。
        #expect(!isFullScreen(CGRect(x: 0, y: 1, width: 1512, height: 982)))
    }

    @Test("普通窗口不算全屏")
    func regularWindowIsNotFullScreen() {
        #expect(!isFullScreen(CGRect(x: 200, y: 100, width: 900, height: 600)))
    }

    @Test("宽或高差一点就不算 —— 只放行 1pt 的取整误差")
    func nearlyFullScreenIsRejected() {
        #expect(isFullScreen(CGRect(x: 0, y: 0, width: 1511, height: 981)))
        #expect(!isFullScreen(CGRect(x: 0, y: 0, width: 1508, height: 982)))
        #expect(!isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 978)))
    }

    @Test("比屏幕还大的窗口算全屏")
    func oversizedCountsAsFullScreen() {
        #expect(isFullScreen(CGRect(x: -2, y: -2, width: 1516, height: 986)))
    }
}
