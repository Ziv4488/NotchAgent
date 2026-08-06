//
//  AppTabPersistenceTests.swift
//  NotchAgentTests
//
//  app tab 的身份存不存得住，以及**旧的 tabs.json 还读不读得动**。
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("app tab 的持久化")
@MainActor
struct AppTabPersistenceTests {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-apptab-\(UUID().uuidString).json")
    }

    /// **夹具照抄用户真的那份 `tabs.json`**（08-07 从
    /// `~/Library/Application Support/NotchAgent/` 取的形状）：只有
    /// `id` / `title` / `directory` 三个键 —— `claudeSessionID` 是 nil，
    /// `JSONEncoder` 把它整个省掉了，`appBundleID` 那时还不存在。
    ///
    /// 这条守的是「**升级不能把人家的 tab 弄丢**」。`appBundleID` 写成可选字段
    /// 就是为了这个：Codable 合成的解码器对可选属性走 `decodeIfPresent`，
    /// 缺键解出来是 nil，也正好是「这是 CLI tab」。要是当初图直白加了个
    /// 必填的 `kind` 枚举，整个文件会解码失败，`load` 返回空数组，
    /// 用户开机发现 tab 全没了。
    private let legacyJSON = """
    [
      {"id":"60B13B97-D545-4910-85CD-B8B135512639","title":"CC1","directory":"/Users/x/自动化/CC1"},
      {"id":"2606E45E-FD3B-42A1-8304-0F3DB7B11493","title":"抖音话题找达人","directory":"/Users/x/自动化/抖音"}
    ]
    """

    @Test("读得动 08-07 之前的 tabs.json，全部当 CLI tab")
    func loadsLegacyFile() throws {
        let url = tempURL()
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshots = TabStore.load(from: url)
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.appBundleID == nil })
        #expect(snapshots.first?.title == "CC1")
    }

    @Test("app tab 存得下 bundle id，读回来还是 app tab")
    func appTabRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshots = [
            TabSnapshot(id: UUID(), title: "写测试", directory: "/tmp/a",
                        claudeSessionID: "c1", appBundleID: nil),
            TabSnapshot(id: UUID(), title: "ChatGPT", directory: nil,
                        claudeSessionID: nil, appBundleID: "com.openai.codex"),
        ]
        TabStore.save(snapshots, to: url)
        #expect(TabStore.load(from: url) == snapshots)
    }

    /// 08-07 之前 `persistTabs` 直接 `filter { $0.kind == .cli }` 把 app tab 扔了。
    /// 那时它只是个调试用的假壳，没有身份可存；现在它带着 bundle id 了。
    @Test("持久化不再把 app tab 扔掉")
    func appTabsSurvivePersist() throws {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.tabStoreURL = tempURL()
        defer { try? FileManager.default.removeItem(at: model.tabStoreURL) }
        model.attach(runtime: SessionRuntime())

        model.debugStartSession(named: "refactor-auth")
        model.debugAttachApp(named: "ChatGPT", bundleID: "com.openai.codex")
        model.persistTabs()

        let saved = TabStore.load(from: model.tabStoreURL)
        #expect(saved.count == 2)
        #expect(saved.contains { $0.appBundleID == "com.openai.codex" })
    }

    /// **app tab 不该显示成「已结束 · 可继续」。** 那句话说的是「进程没了，
    /// `--resume` 接得回去」—— 对贴附一个窗口毫无意义，点它也不会去 resume 什么。
    @Test("重启后 app tab 不带「已结束」那套")
    func restoredAppTabIsNotDetached() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        TabStore.save([
            TabSnapshot(id: UUID(), title: "ChatGPT", directory: nil,
                        claudeSessionID: nil, appBundleID: "com.openai.codex"),
            TabSnapshot(id: UUID(), title: "写测试", directory: "/tmp/a",
                        claudeSessionID: nil, appBundleID: nil),
        ], to: url)

        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.tabStoreURL = url
        model.attach(runtime: SessionRuntime())

        let app = try #require(model.tabs.first { $0.isApp })
        #expect(app.appBundleID == "com.openai.codex")
        #expect(!app.isDetached)
        #expect(app.status != .ended)

        // CLI tab 那一半原样不变。
        let cli = try #require(model.tabs.first { !$0.isApp })
        #expect(cli.isDetached)
        #expect(cli.status == .ended)
    }
}
