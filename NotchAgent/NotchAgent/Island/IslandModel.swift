//
//  IslandModel.swift
//  NotchAgent
//
//  岛的可观察状态。第 1 阶段全部由假数据 + 调试菜单驱动，
//  第 2 阶段把 tabs 换成真实会话、把事件源换成 StatusFeed。
//

import SwiftUI
import Observation

/// 会话的额度、模式与子代理。
///
/// 第 1 阶段是假数据。第 2 阶段由 Claude Code 侧喂进来：额度三项走 `/usage`
/// 或 statusline，mode 与 subagent 走 hook —— 换数据源时只动填充方，不动这个结构。
struct SessionUsage: Equatable {
    /// 上下文窗口已用比例 0...1。
    var contextUsed: Double = 0
    /// 5 小时滚动窗口已用比例 0...1。
    var fiveHourUsed: Double = 0
    /// 周额度已用比例 0...1。
    var weeklyUsed: Double = 0
    /// 当前权限模式。
    var mode: Mode = .manual
    /// 正在跑的子代理数量。
    var subagents: Int = 0

    /// Claude Code 的四档权限模式，⇧Tab 依次轮换。
    ///
    /// 名称与顺序照抄 Claude Code 自己的模式选单（Manual / Accept edits / Plan / Auto），
    /// **不翻译** —— 岛显示的档位必须和用户在终端里看到的是同一个词，
    /// 否则「我现在到底在哪个模式」这件最要紧的事会对不上。
    enum Mode: CaseIterable, Equatable {
        case manual, acceptEdits, plan, auto

        var label: String {
            switch self {
            case .manual: "Manual"
            case .acceptEdits: "Accept edits"
            case .plan: "Plan"
            case .auto: "Auto"
            }
        }

        /// Manual 之外都要看得见 —— 用户得知道自己现在在什么模式下按回车。
        var isDefault: Bool { self == .manual }
    }
}

/// tab 的一格。第 2 阶段会被 `SessionKit` 的真实会话替换。
struct IslandTab: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Claude Code CLI 会话，岛内原生渲染终端。
        case cli
        /// 第三方 app，真实窗口贴附在岛下方。
        case app
    }

    enum Status: Equatable {
        /// 正在干活。
        case running
        /// 停下来等你回话：权限询问、澄清问题。
        case waiting
        /// 这一轮跑完了。
        case done
        /// 会话已结束。
        case ended
    }

    let id: UUID
    var title: String
    var kind: Kind
    var status: Status
    /// 完成但用户还没点开。
    var unread: Bool
    /// tab 图标底色。
    var accent: Color
    /// 本轮开始的时刻，状态带右侧的计时从这里算。
    var startedAt: Date
    var usage: SessionUsage

    init(id: UUID = UUID(), title: String, kind: Kind, status: Status,
         unread: Bool = false, accent: Color,
         startedAt: Date = .now, usage: SessionUsage = SessionUsage()) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.unread = unread
        self.accent = accent
        self.startedAt = startedAt
        self.usage = usage
    }
}

@Observable
final class IslandModel {
    private(set) var state: IslandState = .idle
    private(set) var tabs: [IslandTab] = []
    var selectedTabID: UUID?
    /// 鼠标是否悬停。只做轻微高亮，不展开、不预览（spec 3.1）。
    var isHovering = false
    /// 正在走新建流程（点了 ＋，或者一个 tab 都没有）。
    var isComposingNewTask = false
    /// 新建流程的项目列表，进入时才扫盘。
    private(set) var projects: [ProjectDirectory] = []

    var geometry: ScreenGeometryProviding
    var constants: IslandConstants
    /// 用户拖拽调整过的展开尺寸，会记住。
    var expandedWidth: CGFloat
    var expandedContentHeight: CGFloat

    init(geometry: ScreenGeometryProviding, constants: IslandConstants = .default) {
        self.geometry = geometry
        self.constants = constants
        self.expandedWidth = constants.expandedWidth
        self.expandedContentHeight = constants.contentHeight
    }

    var metrics: IslandMetrics {
        IslandMetrics(geometry: geometry, constants: constants,
                      expandedWidth: expandedWidth,
                      expandedContentHeight: expandedContentHeight)
    }

    /// 「在等你回话」也算需要处理，和「跑完未读」一样应该把岛推到 notice 态 ——
    /// 卡住等确认却什么都不显示，是最坏的一种沉默。
    var context: IslandContext {
        IslandContext(runningCount: tabs.filter { $0.status == .running }.count,
                      unreadCount: tabs.filter { $0.unread || $0.status == .waiting }.count)
    }

    var selectedTab: IslandTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// 状态带右侧计时跟着谁：选中的那个在跑就用它，否则用最早开始的那个。
    var timedTab: IslandTab? {
        if let selected = selectedTab, selected.status == .running { return selected }
        return tabs.first { $0.status == .running }
    }

    /// notice 态要按 tab 条实际内容宽度撑开。
    var tabStripWidth: CGFloat {
        TabStrip.measuredWidth(for: tabs)
    }

    var size: CGSize { metrics.size(for: state, tabStripWidth: tabStripWidth) }
    var cornerRadii: IslandCornerRadii { metrics.cornerRadii(for: state) }

    // MARK: - 事件

    /// 状态真的变了才回调。窗口层靠它切换 canBecomeKey 与焦点归属。
    var onStateChanged: ((IslandState, IslandState) -> Void)?

    func send(_ event: IslandEvent) {
        // 先让事件作用于数据，再让状态机看**变更后**的计数（见 IslandContext 的约定）。
        applySideEffects(of: event)
        let next = reduce(state, event, context)
        guard next != state else { return }
        let previous = state
        state = next
        onStateChanged?(previous, next)
    }

    private func applySideEffects(of event: IslandEvent) {
        switch event {
        case .tabOpened:
            if let id = selectedTabID, let index = tabs.firstIndex(where: { $0.id == id }) {
                tabs[index].unread = false
            }
        case .allRead:
            for index in tabs.indices { tabs[index].unread = false }
        case .lastSessionEnded:
            tabs.removeAll()
            selectedTabID = nil
        default:
            break
        }
    }

    // MARK: - 展开态拖拽调整尺寸

    /// 尺寸落定的通知。面板不需要跟着改（见 `IslandMetrics.containerFrame`），
    /// 第 2 阶段用它把尺寸写进 Application Support。
    var onExpandedSizeChanged: (() -> Void)?

    var expandedWidthRange: ClosedRange<CGFloat> { metrics.expandedWidthRange }
    var expandedContentHeightRange: ClosedRange<CGFloat> { metrics.expandedContentHeightRange }

    /// 拖拽手柄调用。传的是**目标绝对尺寸**，不是增量 ——
    /// 手柄自己会随岛一起移动，用增量累加必然漂。
    func resizeExpanded(width: CGFloat, contentHeight: CGFloat) {
        let w = width.clamped(to: expandedWidthRange)
        let h = contentHeight.clamped(to: expandedContentHeightRange)
        guard w != expandedWidth || h != expandedContentHeight else { return }
        expandedWidth = w
        expandedContentHeight = h
        onExpandedSizeChanged?()
    }

    /// 岛主体当前的四条边在屏幕坐标里的位置（原点左下）。拖拽手柄靠它做绝对定位。
    var expandedEdges: (centerX: CGFloat, topY: CGFloat, bottomY: CGFloat) {
        let top = geometry.screenTopY
        return (geometry.islandCenterX, top, top - metrics.size(for: .expanded).height)
    }

    // MARK: - 模式

    /// ⇧Tab 轮换当前会话的权限模式。
    func cycleMode() {
        guard let id = selectedTab?.id,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let all = SessionUsage.Mode.allCases
        let current = all.firstIndex(of: tabs[index].usage.mode) ?? 0
        tabs[index].usage.mode = all[(current + 1) % all.count]
    }

    /// 中断当前会话。第 2 阶段这里改成给 PTY 发 Esc / SIGINT。
    func interruptSelectedTask() {
        guard let id = selectedTab?.id,
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].status == .running else { return }
        tabs[index].status = .done
        // 是用户自己按的停止，人就在跟前看着，不该再标成未读去催他。
        tabs[index].unread = false
        send(.sessionStopped)
    }

    func selectTab(_ id: UUID) {
        isComposingNewTask = false
        selectedTabID = id
        send(.tabOpened)
    }

    // MARK: - 新建任务（spec 3.3）

    /// 一个 tab 都没有时，展开就应该直接落在新建流程上，不然岛是空的。
    var showsNewTaskForm: Bool { isComposingNewTask || tabs.isEmpty }

    func beginNewTask() {
        projects = ProjectDirectoryStore.recent()
        isComposingNewTask = true
        if state != .expanded { send(.click) }
    }

    func cancelNewTask() {
        isComposingNewTask = false
    }

    /// 第 1 阶段先造个假会话把流程跑通；第 2 阶段这里换成真的起 `claude`。
    func startTask(in project: ProjectDirectory, instruction: String) {
        _ = instruction
        isComposingNewTask = false
        debugStartSession(named: project.name)
        selectedTabID = tabs.last?.id
    }

    // MARK: - 第 1 阶段的调试入口

    /// 造一个在跑的假会话。
    func debugStartSession(named name: String) {
        let tab = IslandTab(title: name, kind: .cli, status: .running,
                            accent: Color(red: 0.85, green: 0.47, blue: 0.34),
                            usage: SessionUsage(contextUsed: 0.42, fiveHourUsed: 0.31,
                                                weeklyUsed: 0.12, mode: .manual, subagents: 2))
        tabs.append(tab)
        if selectedTabID == nil { selectedTabID = tab.id }
        send(.sessionStarted)
    }

    /// 造一个贴附的假第三方 app tab。
    func debugAttachApp(named name: String) {
        let tab = IslandTab(title: name, kind: .app, status: .running, accent: Color(red: 0.06, green: 0.64, blue: 0.50))
        tabs.append(tab)
        if selectedTabID == nil { selectedTabID = tab.id }
        send(.sessionProgress)
    }

    /// 让最早那个还在跑的会话停下来问你 —— 用来看「询问」态长什么样。
    func debugAskOldestRunning() {
        guard let index = tabs.firstIndex(where: { $0.status == .running }) else { return }
        tabs[index].status = .waiting
        send(.sessionProgress)
    }

    /// 直接摆到某个形态，供预览与手动测试。
    func previewState(_ state: IslandState) {
        switch state {
        case .idle:
            break
        case .running:
            debugStartSession(named: "refactor-auth")
        case .notice:
            debugStartSession(named: "refactor-auth")
            debugStartSession(named: "写测试")
            debugAttachApp(named: "ChatGPT")
            debugFinishOldestRunning()
        case .expanded:
            debugStartSession(named: "refactor-auth")
            debugStartSession(named: "写测试")
            debugAttachApp(named: "ChatGPT")
            send(.click)
        }
    }

    /// 让最早那个还在跑的会话完成。
    func debugFinishOldestRunning() {
        guard let index = tabs.firstIndex(where: { $0.status == .running }) else { return }
        tabs[index].status = .done
        tabs[index].unread = true
        send(.sessionStopped)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
