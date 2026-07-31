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
