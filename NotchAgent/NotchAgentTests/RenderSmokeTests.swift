//
//  RenderSmokeTests.swift
//  NotchAgentTests
//
//  把岛真的渲染一遍，四个形态各一次。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// 让整棵视图树真的走一遍布局。
///
/// **这一套是被一次真事逼出来的。** `TabStrip.measuredWidth` 里往
/// `[.font:]` 塞了个裸写的 `font` —— `TabStrip` 是 `View`，那个名字解析成了
/// 没被调用的 `View.font(_:)` 修饰器。字典值类型是 `Any`，编译器一声不吭，
/// 188 个单元测试也全绿，因为没有一个会去**渲染**。
/// app 一启动，AppKit 拿着那个 `__SwiftValue` 去问 `pointSize`，第一帧就崩。
///
/// 这里不断言长什么样（那是截图的事），只断言**画得出来**。
@Suite("岛画得出来")
@MainActor
struct RenderSmokeTests {

    /// 强制走一遍完整布局。`layoutSubtreeIfNeeded` 会真的调用视图的 body
    /// 与所有尺寸计算 —— 上面那个崩溃就是在这一步发生的。
    private func render(_ view: some View, width: CGFloat = 700, height: CGFloat = 430) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
    }

    @Test("四个形态都画得出来", arguments: IslandState.allCases)
    func rendersEveryState(state: IslandState) {
        render(IslandShell(model: .previewModel(state: state)))
    }

    /// notice 态的岛宽是按 tab 标题**量**出来的，这条路径上有真实的字体测量。
    @Test("tab 条画得出来，也量得出宽度", arguments: [
        ["a"], ["Agent灵动岛"], ["a", "b", "c"], ["名字特别长的一个会话", "x"],
    ])
    func rendersTabStrip(titles: [String]) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        for title in titles { model.debugStartSession(named: title) }
        render(TabStrip(model: model), height: 34)
        #expect(model.tabStripWidth > 0)
    }

    /// 一个 tab 都没有时展开态落在新建表单上，那是另一条渲染路径。
    @Test("新建表单画得出来")
    func rendersNewTaskForm() {
        render(NewTaskForm(projects: ProjectDirectoryStore.recent(),
                           error: "找不到 claude",
                           onSubmit: { _, _ in }, onCancel: {}))
    }

    /// **`~/.claude/projects` 是空的时候也得画得出「选择其他目录…」。**
    ///
    /// 那一行原来在滚动列表里，空列表干脆整支不绘制 —— 而空态文案还写着
    /// 「用下面的选择其他目录…」，指着一个不存在的按钮。用户报的
    /// 「开不了一个没有会话的目录，只能 resume」就是这么来的。
    @Test("一个项目都没有时，新建表单也画得出来")
    func rendersNewTaskFormWithoutProjects() {
        render(NewTaskForm(projects: [], onSubmit: { _, _ in }, onCancel: {}))
    }

    /// 会话结束后内容区换成「继续上次会话」，也要画得出来。
    /// 非零退出走的是另一支（警告标 + 退出码 + 「重新启动」）。
    @Test("已结束会话的内容区画得出来", arguments: [Int32(0), 1, 128 + SIGTERM])
    func rendersDetachedContent(exitCode: Int32) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        model.apply(.finished(exitCode), to: model.tabs[0].id)
        render(ContentArea(model: model, tab: model.tabs[0]))
    }

    /// tab 多到装不下时 tab 条要横向滚动（`ScrollView` + `ScrollViewReader`）。
    /// 这条只保证那一层包装画得出来 —— 真的滚不滚得动是手测 §13.13。
    @Test("十几个 tab 的 tab 条画得出来")
    func rendersOverflowingTabStrip() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        for index in 1...14 { model.debugStartSession(named: "会话-\(index)") }
        render(TabStrip(model: model), width: 560, height: 34)
        // 撑爆了才算测到了溢出这条路。
        #expect(model.tabStripWidth > model.metrics.expandedWidth)
    }
}
