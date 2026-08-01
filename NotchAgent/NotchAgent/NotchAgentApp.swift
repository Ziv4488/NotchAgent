//
//  NotchAgentApp.swift
//  NotchAgent
//
//  Created by Ziv on 2026/7/30.
//

import SwiftUI
import AppKit

@main
struct NotchAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 岛是 NSPanel、菜单栏项是 NSStatusItem，都在 AppDelegate 里建。
        // 这里必须有一个 Scene，但不该有窗口 —— Settings 是唯一不会自己冒出来的。
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel(geometry: ScreenGeometry.main ?? FakeScreenGeometry.macBook14)
    private let runtime = SessionRuntime()
    private var controller: IslandWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = IslandWindowController(model: model)
        controller.start()
        self.controller = controller

        installStatusItem()
        model.confirmCloseLiveTab = Self.confirmCloseLiveTab

        // 手动测试用：--args -debugState running|notice|expanded|newtask 直接开在某个形态。
        // 这条路走假数据，**不接 runtime** —— 否则一开 app 就会去起真的 claude。
        if let raw = UserDefaults.standard.string(forKey: "debugState") {
            if raw == "newtask" {
                model.beginNewTask()
            } else {
                IslandState(rawValue: raw).map(model.previewState)
            }
            return
        }

        runtime.start()
        model.attach(runtime: runtime)

        // 手动测试用：--args -debugTask <目录> 直接在该目录起一个**真**会话并展开，
        // 免得每次都要走菜单 → 选目录 → 打字。和上面的 -debugState 是两回事：
        // 那个走假数据不碰 runtime，这个走的是完整的真实链路。
        if let path = UserDefaults.standard.string(forKey: "debugTask") {
            let instruction = UserDefaults.standard.string(forKey: "debugPrompt")
            model.startTask(in: ProjectDirectory(path: path, lastUsed: .now, hasSessions: false),
                            instruction: instruction ?? "")
            model.send(.click)
        }
    }

    /// 有任务在跑就先问一声（spec 5.4）。
    ///
    /// v1 的任务是 app 的子进程，退出 app 就等于把它们全杀了 ——
    /// 这件事必须问，不能默默做掉。
    ///
    /// **必须让岛下去**，和文件选择框一个道理（见 `NotchWindow.steppingAside`）。
    /// 岛压在 `statusBar + 1`（26）上，`NSAlert` 是 `.modalPanel`（8），展开态的画布
    /// 又有 1368×835 那么大 —— 弹框正好整个落在它底下。实机上抓到过：
    /// `layer=26 bounds=72,0 1368x835` 盖着 `layer=8 bounds=626,200 260x235`。
    ///
    /// 那时候 app 并没有崩，它在 `runModal()` 里等一个**看不见的**按钮：
    /// 界面全无反应、菜单栏点退出也没用（已经在模态循环里了），只能去活动监视器强杀。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime.hasLiveSessions else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "还有任务在跑"
        alert.informativeText = "退出会终止所有正在运行的 Claude Code 会话。会话记录留在 ~/.claude，下次可以继续。"
        alert.addButton(withTitle: "退出并终止")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        // 岛是 LSUIElement，没有普通窗口，弹框默认可能出现在别的 app 后面。
        NSApp.activate(ignoringOtherApps: true)
        let response = NotchWindow.steppingAside { alert.runModal() }
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// 关一个还在跑的 tab 之前先问一声（用户 2026-08-02 要的）。
    ///
    /// 和退出确认是同一件事的两个尺度：那一下点下去，一个正在干活的会话就没了，
    /// 跑到一半的那一轮丢掉。退 app 早就有确认框，关 tab 一直没有。
    ///
    /// **弹框同样要让岛先下去**，理由见 `applicationShouldTerminate`
    /// —— 岛压在 `statusBar + 1`，展开态的画布能把整个 `NSAlert` 盖住。
    private static func confirmCloseLiveTab(_ tab: IslandTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "「\(tab.title)」还在跑"
        alert.informativeText = "关掉这个 tab 会终止它的 Claude Code 会话。"
            + "会话记录留在 ~/.claude，之后还能用「继续上次会话」接回去。"
        alert.addButton(withTitle: "关掉并终止")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return NotchWindow.steppingAside { alert.runModal() } == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.persistTabs()
        runtime.shutdown()
    }

    /// 用 NSStatusItem 而不是 SwiftUI 的 MenuBarExtra：菜单内容要从 AppDelegate 直接驱动，
    /// 手写 NSMenu 比让 SwiftUI Scene 持有 model 更直接。
    ///
    /// 注意：第三方状态项在 CGWindowList 里由「控制中心」统一合成、报成匿名的 Item-0，
    /// 所以**不能**靠窗口列表里找不到自己的名字就断定图标没建出来 —— 要开关 app 数个数。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "NotchAgent")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "新建任务…", action: #selector(newTask), keyEquivalent: "n").target = self
        menu.addItem(.separator())

        // 第 1 阶段的手动事件源。第 2 阶段由 StatusFeed 的真实事件取代。
        for (title, selector) in [
            ("新建假会话 refactor-auth", #selector(debugStartA)),
            ("新建假会话 写测试", #selector(debugStartB)),
            ("贴附 ChatGPT", #selector(debugAttach)),
            ("最早的会话开始问你", #selector(debugAsk)),
            ("完成最早的会话", #selector(debugFinish)),
            ("展开", #selector(debugExpand)),
            ("收起", #selector(debugDismiss)),
            ("全部已读", #selector(debugAllRead)),
            ("清空会话", #selector(debugClear)),
        ] {
            menu.addItem(withTitle: title, action: selector, keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 NotchAgent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func newTask() { model.beginNewTask() }
    @objc private func debugStartA() { model.debugStartSession(named: "refactor-auth") }
    @objc private func debugStartB() { model.debugStartSession(named: "写测试") }
    @objc private func debugAttach() { model.debugAttachApp(named: "ChatGPT") }
    @objc private func debugAsk() { model.debugAskOldestRunning() }
    @objc private func debugFinish() { model.debugFinishOldestRunning() }
    @objc private func debugExpand() { model.send(.click) }
    @objc private func debugDismiss() { model.send(.dismiss) }
    @objc private func debugAllRead() { model.send(.allRead) }
    @objc private func debugClear() { model.send(.lastSessionEnded) }
}
