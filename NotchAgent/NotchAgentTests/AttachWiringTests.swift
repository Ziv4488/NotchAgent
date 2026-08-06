//
//  AttachWiringTests.swift
//  NotchAgentTests
//
//  岛这边怎么驱动贴附：什么时候接管、什么时候藏、什么时候还，
//  以及拖拽那一路上帧是怎么被合并掉的。
//

import CoreGraphics
import Foundation
import Testing
@testable import NotchAgent

/// 手动泵的执行器。`AttachDriver` 的合并逻辑只有在「有东西堵在路上」时才看得见，
/// 用真队列测就成了赛跑，用同步执行器又永远堵不住 —— 只能自己控制什么时候放行。
@MainActor
private final class ManualExecutor {
    private var queue: [(work: () -> Void, done: () -> Void)] = []
    var pendingCount: Int { queue.count }

    func install(on driver: AttachDriver) {
        driver.perform = { [weak self] work, done in
            self?.queue.append((work, done))
        }
    }

    /// 放行一个。`done` 会同步回调，于是驱动有机会把下一帧泵出来。
    @discardableResult
    func drainOne() -> Bool {
        guard !queue.isEmpty else { return false }
        let item = queue.removeFirst()
        item.work()
        item.done()
        return true
    }

    func drainAll() { while drainOne() {} }
}

@Suite("岛怎么驱动贴附")
@MainActor
struct AttachWiringTests {

    private func staged(minimum: CGSize = .zero)
    -> (IslandModel, FakeAX, ManualExecutor, FakeWindow) {
        let ax = FakeAX()
        ax.minimumSize = minimum
        let window = ax.stage("com.openai.codex", window: 1,
                              at: CGRect(x: 272, y: 86, width: 1164, height: 806))

        let core = WindowAttach(ax: ax)
        core.sleep = { _ in }
        let driver = AttachDriver(core: core)
        // **别写用户真的那份账本。** 08-07 漏过一次：默认路径直指
        // ~/Library/Application Support/NotchAgent/attached-windows.json，
        // 跑完测试那儿就多出一笔假欠账 —— 下次真的启动会照着它去挪窗口。
        driver.ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-loans-\(UUID().uuidString).json")
        let executor = ManualExecutor()
        executor.install(on: driver)

        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.tabStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-attach-\(UUID().uuidString).json")
        model.attach = driver
        return (model, ax, executor, window)
    }

    // MARK: - 岛让出内容区

    /// **岛体是不透明的 `.fill(.black)`**（`IslandShell.edges`）。选中 app tab
    /// 时不缩成 chrome 的话，那块黑直接把贴在下面的窗口盖没了 —— 用户看到的是
    /// 一块黑，会以为贴附失败。
    @Test("选中 app tab 时岛缩成只剩状态带 + tab 条")
    func islandShrinksForAppTabs() {
        let (model, _, _, _) = staged()
        model.debugStartSession(named: "refactor-auth")
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)

        let full = model.size.height
        model.selectTab(model.tabs.last!.id)          // 切到 app tab
        #expect(model.size.height == model.metrics.chromeOnlyHeight)
        #expect(model.size.height < full)

        model.selectTab(model.tabs.first!.id)         // 切回 CLI tab
        #expect(model.size.height == full)
    }

    // MARK: - 接管 / 藏 / 还

    @Test("切到 app tab 就接管它的窗口，尺寸是内容区那块")
    func selectingAnAppTabAttaches() {
        let (model, ax, executor, window) = staged()
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()

        let content = model.metrics.contentRectOnScreen
        let now = try? #require(ax.frame(of: window))
        #expect(now?.size == content.size)
        #expect(ax.activated.contains("com.openai.codex"))
    }

    /// 收起岛只**藏**不还原（`hide` 等价 ⌘H）。还原是把窗口放回用户原来摆的地方，
    /// 那属于「不玩了」；每次切来切去都还一遍的话，窗口会在屏幕上来回蹦。
    @Test("收起岛只藏起来，不还原")
    func collapsingHidesButDoesNotRestore() throws {
        let (model, ax, executor, window) = staged()
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()
        let attached = try #require(ax.frame(of: window))

        model.send(.dismiss)
        executor.drainAll()

        #expect(ax.hidden.contains("com.openai.codex"))
        #expect(ax.frame(of: window) == attached)      // 还在岛给的位置上
    }

    /// spec 6.3 的硬性要求。挪的是**别人的**窗口，岛只是暂借。
    @Test("移除 app tab，窗口回原位")
    func closingAnAppTabRestores() {
        let (model, ax, executor, window) = staged()
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()
        #expect(ax.frame(of: window) != original)

        model.closeTab(model.tabs.first!.id)
        executor.drainAll()
        #expect(ax.frame(of: window) == original)
    }

    // MARK: - 最小尺寸反过来钉住岛

    /// spec 6.4 原本写的是「压不住就把岛加宽」，那是事后补救。
    /// 反过来钉住拖拽下限更干净 —— 根本不让用户拖到窗口做不到的尺寸去。
    @Test("目标窗口压不下去时，岛的拖拽下限被顶起来")
    func minimumWindowSizeRaisesTheDragFloor() {
        let (model, _, executor, _) = staged(minimum: CGSize(width: 900, height: 700))
        let floorBefore = model.expandedWidthRange.lowerBound

        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()

        #expect(model.expandedWidthRange.lowerBound == 900)
        #expect(model.expandedWidthRange.lowerBound > floorBefore)
        // 高度那一侧要换算回「内容区」口径（贴附占的是内容区 + 退休的输入框 44pt）。
        #expect(model.expandedContentHeightRange.lowerBound
                == 700 - model.constants.retiredInputBarHeight)
    }

    @Test("没被钳制时拖拽下限不动")
    func noClampMeansNoChange() {
        let (model, _, executor, _) = staged()      // minimumSize = .zero
        let before = model.expandedWidthRange
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()
        #expect(model.expandedWidthRange == before)
    }

    // MARK: - 岛崩了怎么办

    /// **`applicationWillTerminate` 只覆盖正常退出。** 被强杀、崩溃、断电时，
    /// 用户的窗口就永远卡在岛给的尺寸上，而岛下次起来根本不知道自己欠着账 ——
    /// 除非原始 frame 在磁盘上另有一份。
    @Test("岛没走 willTerminate 就没了，下次启动把窗口还回去")
    func outstandingWindowsAreReclaimedAfterACrash() throws {
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-loans-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        let ax = FakeAX()
        let original = CGRect(x: 272, y: 86, width: 1164, height: 806)
        let window = ax.stage("com.openai.codex", window: 1, at: original)

        // 这一轮：接管了，然后进程没了 —— 谁都没来得及还。
        let core = WindowAttach(ax: ax)
        core.sleep = { _ in }
        let driver = AttachDriver(core: core)
        driver.ledgerURL = ledgerURL
        let executor = ManualExecutor()
        executor.install(on: driver)
        driver.attach(bundleID: "com.openai.codex",
                      to: CGRect(x: 100, y: 200, width: 560, height: 342)) { _ in }
        executor.drainAll()

        #expect(ax.frame(of: window) != original)
        #expect(AttachLedgerStore.load(from: ledgerURL).count == 1)

        // 下一轮：全新的 driver（账本在内存里是空的），只有磁盘上那笔。
        let revived = AttachDriver(core: WindowAttach(ax: ax))
        revived.ledgerURL = ledgerURL
        let executor2 = ManualExecutor()
        executor2.install(on: revived)
        revived.reclaimOutstanding()
        executor2.drainAll()

        #expect(ax.frame(of: window) == original)
        #expect(AttachLedgerStore.load(from: ledgerURL).isEmpty)   // 账清了
    }

    @Test("正常还回去之后，磁盘上的账也划掉")
    func restoringClearsTheLedgerFile() {
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-loans-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        let ax = FakeAX()
        _ = ax.stage("com.openai.codex", window: 1,
                     at: CGRect(x: 272, y: 86, width: 1164, height: 806))
        let core = WindowAttach(ax: ax)
        core.sleep = { _ in }
        let driver = AttachDriver(core: core)
        driver.ledgerURL = ledgerURL
        let executor = ManualExecutor()
        executor.install(on: driver)

        driver.attach(bundleID: "com.openai.codex",
                      to: CGRect(x: 100, y: 200, width: 560, height: 342)) { _ in }
        executor.drainAll()
        #expect(!AttachLedgerStore.load(from: ledgerURL).isEmpty)

        driver.restore(bundleID: "com.openai.codex")
        executor.drainAll()
        #expect(AttachLedgerStore.load(from: ledgerURL).isEmpty)
    }

    // MARK: - 拖拽时的合并

    /// **这是 `AttachDriver` 存在的一半理由。** AX 一次只做得了一个，拖拽每帧
    /// 都会喂一个新矩形进来；排队的话手都松开了窗口还在追之前的帧。
    /// 只留最新那一个，中间的直接丢 —— 反正没人看得见被跳过的中间态。
    @Test("拖拽积压的帧被合并掉，只有最新那个落到 AX 上")
    func draggingCoalescesToTheLatestFrame() throws {
        let (model, ax, executor, window) = staged()
        model.debugAttachApp(named: "ChatGPT")
        model.send(.click)
        executor.drainAll()
        let callsAfterAttach = ax.setFrameCalls

        // 拖拽：连灌 20 帧，一帧都不放行。
        for width in stride(from: 600.0, through: 980.0, by: 20) {
            model.resizeExpanded(width: width, contentHeight: 342)
        }
        // 第一帧在飞，后面 19 帧塌成一个。
        #expect(executor.pendingCount == 1)

        executor.drainAll()
        #expect(ax.setFrameCalls - callsAfterAttach == 2)   // 第一帧 + 最新那帧
        let final = try #require(ax.frame(of: window))
        #expect(final.width == model.metrics.contentRectOnScreen.width)
        #expect(final.width == 980)
    }
}
