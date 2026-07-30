//
//  IslandModel.swift
//  NotchAgent
//
//  岛的可观察状态。第 1 阶段全部由假数据 + 调试菜单驱动，
//  第 2 阶段把 tabs 换成真实会话、把事件源换成 StatusFeed。
//

import SwiftUI
import Observation

/// tab 的一格。第 2 阶段会被 `SessionKit` 的真实会话替换。
struct IslandTab: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Claude Code CLI 会话，岛内原生渲染终端。
        case cli
        /// 第三方 app，真实窗口贴附在岛下方。
        case app
    }

    enum Status: Equatable {
        case running
        case done
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

    init(id: UUID = UUID(), title: String, kind: Kind, status: Status,
         unread: Bool = false, accent: Color) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.unread = unread
        self.accent = accent
    }
}

@Observable
final class IslandModel {
    private(set) var state: IslandState = .idle
    private(set) var tabs: [IslandTab] = []
    var selectedTabID: UUID?
    /// 鼠标是否悬停。只做轻微高亮，不展开、不预览（spec 3.1）。
    var isHovering = false

    var geometry: ScreenGeometryProviding
    var constants: IslandConstants
    /// 用户拖拽调整过的展开宽度，会记住。
    var expandedWidth: CGFloat

    init(geometry: ScreenGeometryProviding, constants: IslandConstants = .default) {
        self.geometry = geometry
        self.constants = constants
        self.expandedWidth = constants.expandedWidth
    }

    var metrics: IslandMetrics {
        IslandMetrics(geometry: geometry, constants: constants, expandedWidth: expandedWidth)
    }

    var context: IslandContext {
        IslandContext(runningCount: tabs.filter { $0.status == .running }.count,
                      unreadCount: tabs.filter(\.unread).count)
    }

    var selectedTab: IslandTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
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

    func selectTab(_ id: UUID) {
        selectedTabID = id
        send(.tabOpened)
    }

    // MARK: - 第 1 阶段的调试入口

    /// 造一个在跑的假会话。
    func debugStartSession(named name: String) {
        let tab = IslandTab(title: name, kind: .cli, status: .running, accent: Color(red: 0.85, green: 0.47, blue: 0.34))
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
