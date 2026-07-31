//
//  NotchWindow.swift
//  NotchAgent
//
//  承载岛的面板。探针 B 的四个焦点条件在这里落地。
//

import AppKit
import OSLog
import SwiftUI

final class NotchWindow: NSPanel {

    private let log = Logger(subsystem: "com.notchagent", category: "focus")

    /// 由外部决定当前是否允许成为 key —— 只有 expanded 态返回 true（spec 11.2）。
    var allowsKeyProvider: () -> Bool = { false }

    /// 展开前的前台 app，收起时把焦点还回去。规则见 `FocusHandoff`。
    private var handoff = FocusHandoff()

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
        let previous = NSWorkspace.shared.frontmostApplication
        log.info("展开：记下 \(previous?.bundleIdentifier ?? "无", privacy: .public)")
        handoff.remember(previous)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeMain()
        if let firstResponder {
            makeFirstResponder(firstResponder)
            firstResponder.inputContext?.activate()
        }
        raiseInputMethodWindows()
    }

    /// 收起时把焦点交还给展开前那个 app。谁都不还是正常情况，见 `FocusHandoff`。
    func giveBackFocus() {
        orderFront(nil)
        let target = handoff.appToRestore()
        log.info("收起：还给 \(target?.bundleIdentifier ?? "谁都不还", privacy: .public)")
        target?.activate()
    }

    /// 展开期间别的 app 抢了前台，作废这次的焦点记录。
    func forgetFocusHandoff(because app: String) {
        log.info("别人抢了前台（\(app, privacy: .public)），这次不还焦点了")
        handoff.someoneElseTookOver()
    }

    /// 在一个模态框（`NSOpenPanel` 之类）期间，把所有岛让到普通层级。
    ///
    /// 岛压在菜单栏之上（`statusBar + 1`），系统的文件选择框是个普通窗口，
    /// 不让位就会被岛盖掉中间一大块 —— 实机上侧栏和按钮露在外面、文件列表被吞了。
    ///
    /// **反过来抬高 panel 的 level 是行不通的**：试过，`runModal()` 里被 AppKit
    /// 重置了。我们只对自己的窗口说了算，所以让岛下去。降到 `.normal` 而不是藏起来：
    /// 岛还看得见，只是不再压着模态框。
    static func steppingAside<T>(_ body: () -> T) -> T {
        let islands = NSApp.windows.compactMap { $0 as? NotchWindow }
        let saved = islands.map(\.level)
        for island in islands { island.level = .normal }
        defer {
            for (island, level) in zip(islands, saved) { island.level = level }
        }
        return body()
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
        if event.type == .leftMouseDown { claimKeyboard() }
        super.sendEvent(event)
        // 候选框是打字过程中才出现的，每次按键后都补一次。
        if event.type == .keyDown { raiseInputMethodWindows() }
    }

    /// 点岛的那一下，**同时**就把键盘拿回来。
    ///
    /// 用户报的：「焦点返回的时候要先把焦点切回岛，再进行操作」—— 两下才成一件事。
    /// 原因是岛是 `.nonactivatingPanel`：点它不激活 app，所以点击本身照常送达
    /// （SwiftUI 的按钮、终端的选区都有反应），但**键盘还在别人那儿** ——
    /// 于是「点一下没反应」的其实是接下来的打字。用户于是学会了先点一下、再操作。
    ///
    /// 这里在事件下发**之前**激活：同一下点击既拿到键盘，也照常被下面的视图收到。
    ///
    /// 只在本来就该拿键盘的时候做（展开态，或收起态挂着输入框）——
    /// 收起态点岛只是展开，那条路上的焦点由 `takeFocus()` 负责，不该在这里抢。
    func claimKeyboard() {
        guard allowsKeyProvider() else { return }
        if !NSApp.isActive {
            // 他是从某个 app 点过来的，收起时该还给那个 app（见 `FocusHandoff`）。
            handoff.rememberIfEmpty(NSWorkspace.shared.frontmostApplication)
            NSApp.activate()
        }
        if !isKeyWindow {
            makeKeyAndOrderFront(nil)
            makeMain()
        }
    }
}
