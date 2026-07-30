//
//  ScreenGeometry.swift
//  NotchAgent
//
//  屏幕几何：菜单栏高度与刘海宽度。所有尺寸在运行时推导，不写死。
//

import AppKit

protocol ScreenGeometryProviding {
    /// 菜单栏高度。有刘海时等于刘海高度（safeAreaInsets.top）。
    var menuBarHeight: CGFloat { get }
    /// 刘海实际宽度。nil 表示这块屏没有刘海。
    var notchWidth: CGFloat? { get }
    /// 屏幕整体 frame（全局坐标，原点在左下）。
    var screenFrame: CGRect { get }
}

extension ScreenGeometryProviding {
    var hasNotch: Bool { notchWidth != nil }

    /// 岛的水平中心。刘海在内置屏上永远居中，所以取屏幕中线。
    var islandCenterX: CGFloat { screenFrame.midX }

    /// 岛的顶边（全局坐标）。
    var screenTopY: CGFloat { screenFrame.maxY }
}

/// 从 NSScreen 读取真实几何。
struct ScreenGeometry: ScreenGeometryProviding {
    let menuBarHeight: CGFloat
    let notchWidth: CGFloat?
    let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame

        // 无刘海屏 safeAreaInsets.top 为 0，此时用 frame 与 visibleFrame 的差推菜单栏高度。
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            menuBarHeight = safeTop
        } else {
            let gap = screen.frame.maxY - screen.visibleFrame.maxY
            menuBarHeight = gap > 0 ? gap : Self.fallbackMenuBarHeight
        }

        // auxiliaryTopLeftArea / auxiliaryTopRightArea 是刘海两侧可用的菜单栏区域，
        // 二者之间的空隙就是刘海本体。任一为 nil 说明没有刘海。
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            notchWidth = gap > 0 ? gap : nil
        } else {
            notchWidth = nil
        }
    }

    static let fallbackMenuBarHeight: CGFloat = 24

    /// 当前主屏的几何。菜单栏所在的屏就是 `NSScreen.main`。
    static var main: ScreenGeometry? {
        guard let screen = NSScreen.main else { return nil }
        return ScreenGeometry(screen: screen)
    }
}

/// 测试注入用。
struct FakeScreenGeometry: ScreenGeometryProviding {
    var menuBarHeight: CGFloat
    var notchWidth: CGFloat?
    var screenFrame: CGRect

    /// 14" MacBook Pro：刘海宽约 200pt，菜单栏 32pt。
    static let macBook14 = FakeScreenGeometry(
        menuBarHeight: 32, notchWidth: 200,
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))

    /// 16" MacBook Pro：刘海略宽，菜单栏同高。
    static let macBook16 = FakeScreenGeometry(
        menuBarHeight: 32, notchWidth: 220,
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117))

    /// 无刘海的内置屏（如 MacBook Air M1）。
    static let noNotch = FakeScreenGeometry(
        menuBarHeight: 24, notchWidth: nil,
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

    /// 外接 4K 显示器为主屏：无刘海，且原点不在 (0,0)。
    static let external = FakeScreenGeometry(
        menuBarHeight: 25, notchWidth: nil,
        screenFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1080))
}
