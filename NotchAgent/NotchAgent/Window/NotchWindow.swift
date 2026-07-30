//
//  NotchWindow.swift
//  NotchAgent
//
//  承载岛的面板。探针 B 的四个焦点条件在这里落地。
//

import AppKit
import SwiftUI

final class NotchWindow: NSPanel {

    /// 由外部决定当前是否允许成为 key —— 只有 expanded 态返回 true（spec 11.2）。
    var allowsKeyProvider: () -> Bool = { false }

    /// 展开前的前台 app，收起时把焦点还回去。
    private var previousApp: NSRunningApplication?

    /// 岛的层级。菜单栏是 24、控制中心是 25，都要压过去。
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// 输入法候选框在本进程内、层级固定 20，会被岛盖住。
    /// 岛不可能同时高于菜单栏又低于候选框，只能反过来把候选框抬起来（spec 11.2）。
    private static let inputMethodWindowLevel = 20

    init(contentView: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        self.contentView = contentView

        // 顺序要紧：isFloatingPanel 的 setter 会把 level 改成 .floating(3)，
        // 必须先设它再设 level，否则岛会掉到菜单栏（24）下面去。
        isFloatingPanel = true
        level = Self.islandLevel

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 阴影由 SwiftUI 沿轮廓画，系统窗口阴影是方的
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    /// AppKit 默认会把窗口推到菜单栏下方，岛就贴不到屏幕上沿了。原样返回。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // canBecomeMain 必须和 canBecomeKey 一起为真，否则 NSTextInputContext 不激活，
    // 按键能进来但一个字也插不进去 —— 探针 B 卡了三轮的地方。
    override var canBecomeKey: Bool { allowsKeyProvider() }
    override var canBecomeMain: Bool { allowsKeyProvider() }

    // MARK: - 焦点

    /// 展开时抢焦点。四步缺一不可（spec 11.2）。
    func takeFocus(firstResponder: NSView? = nil) {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeMain()
        if let firstResponder {
            makeFirstResponder(firstResponder)
            firstResponder.inputContext?.activate()
        }
        raiseInputMethodWindows()
    }

    /// 收起时把焦点交还给展开前那个 app。
    func giveBackFocus() {
        orderFront(nil)
        previousApp?.activate()
        previousApp = nil
    }

    /// 把本进程里的输入法候选框抬到岛之上。
    func raiseInputMethodWindows() {
        guard allowsKeyProvider() else { return }
        let target = NSWindow.Level(rawValue: level.rawValue + 1)
        for window in NSApp.windows
        where window !== self && window.isVisible && window.level.rawValue == Self.inputMethodWindowLevel {
            window.level = target
        }
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        // 候选框是打字过程中才出现的，每次按键后都补一次。
        if event.type == .keyDown { raiseInputMethodWindows() }
    }
}
