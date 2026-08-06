//
//  AppRegistryTests.swift
//  NotchAgentTests
//
//  往 ＋ 面板里拖一个 `.app` 进来之后发生什么（用户 08-07 定的入口）。
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchAgent

@Suite("认出拖进来的 app")
@MainActor
struct AppRegistryTests {

    /// **夹具用系统自带的 app，不用 /Applications 里的。** 后者装没装因机器而异，
    /// 拿 ChatGPT 当夹具的话，换台没装的机器整条测试就红了 —— 而它测的
    /// 根本不是「ChatGPT 装没装」。Finder 每台 macOS 都有。
    private let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    private let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    @Test("从 .app 读出 bundle id 和显示名")
    func identifiesARealBundle() throws {
        let app = try #require(AppRegistry.identify(finder))
        #expect(app.bundleID == "com.apple.finder")
        #expect(!app.name.isEmpty)
    }

    @Test("不是 .app 的一律不认")
    func rejectsNonBundles() {
        #expect(AppRegistry.identify(URL(fileURLWithPath: "/etc/hosts")) == nil)
        #expect(AppRegistry.identify(URL(fileURLWithPath: "/Applications")) == nil)
        #expect(AppRegistry.identify(URL(fileURLWithPath: "/nope/Missing.app")) == nil)
    }

    /// 一次拖好几个进来是常事（在 Finder 里多选）。认不出的静静丢掉，
    /// 别因为里面混了个 .txt 就整批拒收。
    @Test("一批里混了认不出的，其余照收")
    func keepsWhatItCanIdentify() {
        let apps = AppRegistry.identify([finder,
                                         URL(fileURLWithPath: "/etc/hosts"),
                                         calculator])
        #expect(apps.count == 2)
        #expect(apps.map(\.bundleID).sorted() == ["com.apple.calculator", "com.apple.finder"])
    }

    /// **按 bundle id 去重，不是按 URL。** `/Applications/X.app` 和桌面上那个
    /// 别名是同一个 app，建两个 tab 只会让它们抢同一个窗口。
    @Test("同一个 app 拖两次只算一个")
    func dedupesByBundleID() {
        #expect(AppRegistry.identify([finder, finder]).count == 1)
    }

    // MARK: - 从剪贴板上取

    /// 造一块只属于这条测试的剪贴板 —— **绝不碰系统那块**（CLAUDE.md：
    /// 别动用户正在用的剪贴板）。
    private func scratchPasteboard(_ objects: [Any]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("notch-drop-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(objects as! [NSPasteboardWriting])
        return board
    }

    @Test("从拖拽的剪贴板上取出文件 URL")
    func readsFileURLsOffThePasteboard() {
        let board = scratchPasteboard([finder as NSURL, calculator as NSURL])
        defer { board.releaseGlobally() }

        let urls = AppRegistry.fileURLs(on: board)
        #expect(urls.count == 2)
        #expect(AppRegistry.identify(urls).map(\.bundleID).sorted()
                == ["com.apple.calculator", "com.apple.finder"])
    }

    /// 从访达拖东西过来，剪贴板上同时挂着好几种表示。**限定只读 file URL**，
    /// 否则一个 `.app` 会被读成两个 URL（`file://` 一个、`public.url` 又一个）。
    @Test("网址不算文件，不取")
    func ignoresNonFileURLs() {
        let board = scratchPasteboard([finder as NSURL,
                                       URL(string: "https://example.com")! as NSURL])
        defer { board.releaseGlobally() }

        #expect(AppRegistry.fileURLs(on: board) == [finder])
    }

    // MARK: - 落到 tab 上

    private func model() -> IslandModel {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.tabStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-drop-\(UUID().uuidString).json")
        model.attach(runtime: SessionRuntime())
        return model
    }

    @Test("拖进来就建一个 app tab 并选中")
    func dropCreatesAnAppTab() throws {
        let model = model()
        defer { try? FileManager.default.removeItem(at: model.tabStoreURL) }

        #expect(model.addAppTabs(from: [finder]))
        let tab = try #require(model.tabs.last)
        #expect(tab.appBundleID == "com.apple.finder")
        #expect(model.selectedTabID == tab.id)
        #expect(!model.isComposingNewTask)
    }

    /// **两个 tab 指着同一个 bundle id 会互相抢那一个窗口**：切到 A 贴上，
    /// 切到 B 又贴一遍，而 B 记的「原始 frame」是 A 贴完之后的样子 ——
    /// 窗口从此再也回不到用户原来摆的地方。
    @Test("已经有这个 app 的 tab 了就选中它，不再建一个")
    func droppingTwiceSelectsTheExistingTab() throws {
        let model = model()
        defer { try? FileManager.default.removeItem(at: model.tabStoreURL) }

        model.addAppTabs(from: [finder])
        let first = try #require(model.tabs.last?.id)

        #expect(model.addAppTabs(from: [finder]))
        #expect(model.tabs.filter(\.isApp).count == 1)
        #expect(model.selectedTabID == first)
    }

    @Test("一个都认不出就不收，也不建 tab")
    func droppingJunkChangesNothing() {
        let model = model()
        defer { try? FileManager.default.removeItem(at: model.tabStoreURL) }

        #expect(!model.addAppTabs(from: [URL(fileURLWithPath: "/etc/hosts")]))
        #expect(model.tabs.isEmpty)
    }
}
