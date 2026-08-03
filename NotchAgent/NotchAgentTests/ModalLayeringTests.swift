//
//  ModalLayeringTests.swift
//  NotchAgentTests
//
//  岛压在菜单栏之上，系统的模态框压不过它 —— 这条钉死。
//

import AppKit
import Testing
@testable import NotchAgent

/// 弹框被岛盖住是**看起来像死机**的那一类 bug：
/// app 停在 `runModal()` 里等一个看不见的按钮，界面全无反应、
/// 菜单栏点退出也没用（已经在模态循环里），只能去活动监视器强杀。
///
/// 实机上抓到过一次，退出确认框：`layer=26 bounds=72,0 1368x835`（岛）
/// 盖着 `layer=8 bounds=626,200 260x235`（`NSAlert`）。
@Suite("模态框与岛的层级")
@MainActor
struct ModalLayeringTests {

    private func makeIsland() -> NotchWindow {
        NotchWindow(contentView: NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    /// 这条解释了 `steppingAside` 为什么必须存在。它红了就说明前提变了。
    @Test("岛本来就压在所有系统模态框之上")
    func islandOutranksModals() {
        for level in [NSWindow.Level.modalPanel, .floating, .normal, .statusBar] {
            #expect(NotchWindow.islandLevel.rawValue > level.rawValue)
        }
    }

    /// 让位期间必须掉到 `.modalPanel` 之下，否则等于没让。
    @Test("让位期间岛低于模态框")
    func stepsBelowModals() {
        let island = makeIsland()
        var levelDuringModal: NSWindow.Level?
        NotchWindow.steppingAside { levelDuringModal = island.level }
        #expect(levelDuringModal.map { $0.rawValue < NSWindow.Level.modalPanel.rawValue } == true)
    }

    /// 让完要还回去。还不回去的话，岛此后就一直被普通窗口盖着，
    /// 它就不是刘海岛了。
    @Test("让位结束后层级复原")
    func restoresLevel() {
        let island = makeIsland()
        let before = island.level
        NotchWindow.steppingAside { }
        #expect(island.level == before)
    }

    /// **`steppingAside` 只还原层级，不还键盘。**
    ///
    /// 用户报的 §13.9「选完目录光标丢了」有一半在这儿：模态期间 key 归模态框，
    /// 结束后 AppKit 把 key 还给它自己记着的那个窗口 —— 不一定是岛。
    /// 窗口不是 key 的话，SwiftUI 那边 `@FocusState` 设成 true 也不会有光标。
    /// 这条钉住「让位这件事本身管不到键盘」，也就是 `reclaimKeyboard()` 存在的理由。
    @Test("让位不负责把键盘还回来")
    func steppingAsideDoesNotTouchTheKeyboard() {
        let island = makeIsland()
        island.allowsKeyProvider = { true }
        var becameKeyDuringModal: Bool?
        NotchWindow.steppingAside { becameKeyDuringModal = island.isKeyWindow }
        #expect(becameKeyDuringModal == false, "让位期间岛不该是 key")
        #expect(island.isKeyWindow == false, "让位结束后也没人替它把键盘拿回来")
    }

    /// `reclaimKeyboard()` 要对**看得见的**岛动手 —— 这是 §13.9 的修法：
    /// 模态框收掉之后先把键盘拿回来，再设 `@FocusState`。
    ///
    /// **断言的是「有没有去做」，不是「做成了没有」。**
    /// 「谁是 key」是全进程共享的一个槽，而 Swift Testing 的套件是并行跑的
    /// （`IslandPixelTests` 就挂真窗口）—— 拿 `isKeyWindow` 当断言必飘：
    /// 第一版这么写，revert 验证时六轮里六轮都红，而它跟那六个改动一个都不相干；
    /// 加了 1 秒重试也没救回来。这种共享的全局状态，并行测试里就是不能断言。
    ///
    /// 「窗口真的成了 key、光标真的回到输入框里」由手测 §13.9 那一行看。
    @Test("reclaimKeyboard 会对看得见的岛动手")
    func reclaimKeyboardActsOnVisibleIslands() {
        let island = makeIsland()
        island.allowsKeyProvider = { true }
        island.orderFront(nil)
        defer { island.orderOut(nil) }

        #expect(NotchWindow.reclaimKeyboard() >= 1, "看得见的岛一个都没被动到")
    }

    /// 藏起来的岛（全屏 Space 里 `orderOut` 掉的那种）不该被这一下拽回前台。
    @Test("看不见的岛不在 reclaimKeyboard 的范围里")
    func reclaimKeyboardSkipsHiddenIslands() {
        let island = makeIsland()
        island.allowsKeyProvider = { true }
        island.orderOut(nil)
        #expect(island.isVisible == false)

        let visibleBefore = NSApp.windows.compactMap { $0 as? NotchWindow }.filter(\.isVisible).count
        #expect(NotchWindow.reclaimKeyboard() == visibleBefore, "藏起来的那个被算进去了")
    }

    /// **收起态的岛不许被这一下拽成 key。**
    ///
    /// `canBecomeKey` 只在展开态为真（spec 11.2）。`reclaimKeyboard` 是无差别地
    /// 对所有看得见的岛调用的，它必须尊重那条闸门 —— 否则 idle 的岛会在
    /// 用户于别处打字时把键盘抢走（§2.5）。
    ///
    /// 闸门在 `claimKeyboard()` 里那句 `guard allowsKeyProvider()`。
    /// 把它去掉，这条测试**会把整个测试进程挂死**（一个 `canBecomeKey == false`
    /// 的窗口被反复要求成为 key，和旁边挂着真窗口的套件顶上了）——
    /// 挂死不是好的失败方式，但它确实说明那道闸门不是可有可无的。
    @Test("收起态的岛不会被 reclaimKeyboard 抢走键盘")
    func reclaimKeyboardRespectsTheCollapsedGate() {
        let island = makeIsland()
        island.allowsKeyProvider = { false }
        defer { island.orderOut(nil) }
        island.orderFront(nil)

        #expect(island.canBecomeKey == false, "收起态的岛压根不该够格拿键盘")
        NotchWindow.reclaimKeyboard()
        #expect(island.isKeyWindow == false)
    }

    /// 模态框里抛出去也得还 —— `defer` 保证的就是这个。
    @Test("模态期间出错也要还回去")
    func restoresLevelOnThrow() {
        struct Boom: Error {}
        let island = makeIsland()
        let before = island.level
        _ = try? NotchWindow.steppingAside { () -> Result<Void, Boom> in .failure(Boom()) }.get()
        #expect(island.level == before)
    }
}
