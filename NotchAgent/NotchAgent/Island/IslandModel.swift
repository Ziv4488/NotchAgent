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
    /// 上下文窗口已用比例 0...1。**nil = 不知道**，界面画一条横线。
    /// 用 0 顶替是错的：「没用」和「不知道」是两件事。
    var contextUsed: Double?
    /// 5 小时滚动窗口已用比例 0...1。nil = 拿不到或数据已过期。
    var fiveHourUsed: Double?
    /// 周额度已用比例 0...1。nil 同上。
    var weeklyUsed: Double?
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

        /// 会话层的状态收敛到岛上的四种。
        ///
        /// `.starting` 归到 `.running`：从用户角度「已经在跑了」，
        /// 为「正在启动」单独做一种视觉，换来的信息量不值那个复杂度。
        init(_ status: SessionStatus) {
            switch status {
            case .starting, .running: self = .running
            case .waiting: self = .waiting
            case .idle: self = .done
            case .finished, .failed: self = .ended
            }
        }
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
    /// 工作目录。重启恢复和「继续上次会话」都要它。
    var directory: String?
    /// 收起态状态带上那行字：「读 session.ts」。由 hook 事件驱动，
    /// 没有事件时是 nil，状态带退回显示项目名。
    var activity: String?
    /// 进程已经退出（正常或异常），只能「继续上次会话」重开。
    var isDetached: Bool

    init(id: UUID = UUID(), title: String, kind: Kind, status: Status,
         unread: Bool = false, accent: Color,
         startedAt: Date = .now, usage: SessionUsage = SessionUsage(),
         directory: String? = nil, activity: String? = nil, isDetached: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.unread = unread
        self.accent = accent
        self.startedAt = startedAt
        self.usage = usage
        self.directory = directory
        self.activity = activity
        self.isDetached = isDetached
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

    /// 「需要你处理」只由 `unread` 一个标志表示。
    ///
    /// 这里原本还加了 `|| $0.status == .waiting`，想的是「卡住等确认」也该催人。
    /// 但那是把同一件事记在两个地方，而其中一个**没有人负责清掉**：
    /// 权限询问来的时候 `demandsAttention` 已经把 `unread` 置上了，
    /// `.waiting` 这一份纯属重复；等用户答完，`unread` 清了、`.waiting` 还挂着，
    /// 于是 `unreadCount` 永远大于 0，岛再也回不到 idle —— 这就是「一直挂着通知态」。
    ///
    /// `.waiting` 现在只管画那个蓝点，不参与「该不该催人」的判断。
    /// 但它要算进 `runningCount`：一个正等着你回话的会话是活的，
    /// 收起时落到 idle 等于说「什么都没在进行」，那是假话。
    var context: IslandContext {
        IslandContext(runningCount: tabs.filter { $0.status == .running || $0.status == .waiting }.count,
                      unreadCount: tabs.filter(\.unread).count)
    }

    var selectedTab: IslandTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// 选中的 tab 背后有没有一个活着的终端。
    ///
    /// 有的话键盘归终端，岛不再画自己的输入框。岛的总高度**不跟着变** ——
    /// 输入框那 44pt 由内容区吸收（它是 `maxHeight: .infinity`），
    /// 否则会话一结束岛就抽搐一下变高，比多 44pt 留白难受得多。
    var selectedTabHasLiveTerminal: Bool {
        guard let id = selectedTab?.id, let session = runtime?.session(id) else { return false }
        return session.status.isAlive
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
        // 点开 tab 是在看它，点开岛同样是 —— 而**光点岛不点 tab 是常态**：
        // 通知弹出来时那个 tab 本来就是选中的，用户直接点岛就开始处理了。
        // 早先只在 `.tabOpened` 清未读，于是这条最常走的路上未读永远清不掉，
        // 岛此后每次收起都落回 notice。
        case .tabOpened, .click:
            markSelectedTabRead()
        case .allRead:
            for index in tabs.indices { tabs[index].unread = false }
        case .lastSessionEnded:
            tabs.removeAll()
            selectedTabID = nil
        default:
            break
        }
    }

    /// 选中的那个 tab 算看过了。
    private func markSelectedTabRead() {
        guard let id = selectedTab?.id,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].unread = false
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
        runtime?.preferences.expandedSize = (w, h)
        onExpandedSizeChanged?()
    }

    /// 岛主体当前的四条边在屏幕坐标里的位置（原点左下）。拖拽手柄靠它做绝对定位。
    var expandedEdges: (centerX: CGFloat, topY: CGFloat, bottomY: CGFloat) {
        let top = geometry.screenTopY
        return (geometry.islandCenterX, top, top - metrics.size(for: .expanded).height)
    }

    // 这里原本有个 `cycleMode()`：⇧Tab 和模式芯片都调它，转发 CSI Z 给 PTY。
    // 两个入口现在都没了 —— ⇧Tab 直接放行给终端（见 IslandWindowController.action），
    // 芯片随用量条一起拆掉。少一层转发，模式切换就是终端自己的事。

    /// 中断当前会话：给 PTY 发 `Esc`，和在终端里按 Esc 完全一样。
    func interruptSelectedTask() {
        guard let id = selectedTab?.id,
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].status == .running else { return }
        runtime?.interrupt(id)
        tabs[index].status = .done
        tabs[index].activity = nil
        // 是用户自己按的停止，人就在跟前看着，不该再标成未读去催他。
        tabs[index].unread = false
        send(.sessionStopped)
    }

    func selectTab(_ id: UUID) {
        isComposingNewTask = false
        selectedTabID = id
        send(.tabOpened)
    }

    /// 给 tab 改个名字。双击 tab 芯片进入编辑（spec 3.2）。
    ///
    /// 默认名是项目目录名，同一个仓库开两个会话就是两个一模一样的 tab，
    /// 分不出哪个在干什么。改完立刻落盘 —— 重启后还叫回目录名等于白改。
    ///
    /// 空白名字**不接受**：tab 芯片会缩成只剩一个图标，谁都点不中它。
    /// 这时候什么都不做、把原名留着，比接受一个不可用的状态好。
    func renameTab(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].title != trimmed else { return }
        tabs[index].title = trimmed
        persistTabs()
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

    /// 真的起一个 `claude`。
    ///
    /// 起不来时**不建 tab**，只把错误挂出去 —— 建一个永远不会有内容的空 tab
    /// 比什么都不建更糟：用户会以为它在跑。
    func startTask(in project: ProjectDirectory, instruction: String, resume: Bool = false) {
        guard let runtime else {
            // 没有 runtime 只会出现在预览和单元测试里。
            isComposingNewTask = false
            debugStartSession(named: project.name)
            selectedTabID = tabs.last?.id
            return
        }

        let id = UUID()
        do {
            try runtime.launch(id: id, title: project.name,
                               directory: URL(fileURLWithPath: project.path),
                               instruction: instruction.isEmpty ? nil : instruction,
                               resume: resume)
        } catch {
            launchError = error.localizedDescription
            return
        }

        isComposingNewTask = false
        launchError = nil
        // 带指令起的会话马上就要干活，不带的（比如 --resume）只是停在提示符前。
        // 后者标成「在跑」就会琥珀色慢呼吸加计时，而它其实什么都没做。
        let willWork = !instruction.isEmpty
        let tab = IslandTab(id: id, title: project.name, kind: .cli,
                            status: willWork ? .running : .done,
                            accent: Self.accent(for: project.path),
                            directory: project.path,
                            activity: willWork ? "启动中" : nil)
        tabs.append(tab)
        selectedTabID = id
        send(.sessionStarted)
        persistTabs()
    }

    /// tab 图标底色按目录路径散列，同一个项目每次都是同一个颜色。
    static func accent(for seed: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.85, green: 0.47, blue: 0.34),
            Color(red: 0.06, green: 0.64, blue: 0.50),
            Color(red: 0.36, green: 0.52, blue: 0.94),
            Color(red: 0.78, green: 0.40, blue: 0.78),
            Color(red: 0.90, green: 0.68, blue: 0.24),
        ]
        let hash = seed.unicodeScalars.reduce(into: 5381) { partial, scalar in
            partial = (partial &* 33) &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    // MARK: - 真实会话（第 2 阶段）

    /// 会话层。预览与单元测试里是 nil，那时岛退回第 1 阶段的假数据行为。
    var runtime: SessionRuntime?
    /// 起不来时给用户看的话（找不到 `claude`、目录没权限之类）。
    var launchError: String?

    func attach(runtime: SessionRuntime) {
        self.runtime = runtime
        runtime.onSignal = { [weak self] id, signal in self?.apply(signal, to: id) }
        runtime.onStatusChanged = { [weak self] id, status in self?.apply(status, to: id) }
        runtime.onMenu = { [weak self] id, menu in self?.apply(menu, to: id) }
        if let size = runtime.preferences.expandedSize {
            expandedWidth = size.width.clamped(to: expandedWidthRange)
            expandedContentHeight = size.contentHeight.clamped(to: expandedContentHeightRange)
        }
        restoreTabs()
    }

    /// hook 事件的结果落到 tab 上。
    func apply(_ signal: SessionSignal, to id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        if let activity = signal.activity { tabs[index].activity = activity }
        if let mode = signal.mode { tabs[index].usage.mode = mode }
        if signal.subagentDelta != 0 {
            tabs[index].usage.subagents = max(0, tabs[index].usage.subagents + signal.subagentDelta)
        }
        if let status = signal.status {
            let mapped = IslandTab.Status(status)
            // 一轮开始就重置计时。状态带右边显示的是「这一轮跑了多久」，
            // 不是「这个 tab 开了多久」—— 后者对判断要不要去看它没有用。
            if mapped == .running, tabs[index].status != .running {
                tabs[index].startedAt = .now
            }
            tabs[index].status = mapped
        }

        // 已经在看着这个 tab 就别标未读 —— 人就在跟前，催他是噪音。
        // 而且要**主动清掉**：他正看着的时候来的事，不该在他收起岛之后
        // 变成一条等着他的未读。
        if signal.demandsAttention {
            let watching = state == .expanded && selectedTab?.id == id
            tabs[index].unread = !watching
        }

        send(signal.demandsAttention ? .sessionStopped : .sessionProgress)
    }

    /// 进程本身的状态（退出、崩溃）落到 tab 上。
    func apply(_ status: SessionStatus, to id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch status {
        case .finished, .failed:
            tabs[index].status = .ended
            tabs[index].isDetached = true
            tabs[index].activity = nil
            if case .failed(let reason) = status { tabs[index].activity = reason }
            send(.sessionStopped)
            persistTabs()
        default:
            tabs[index].status = IslandTab.Status(status)
        }
    }

    // 用量三项（ctx / 5h / 周）原本在这里刷新：每条 hook 事件读一次 transcript 尾部，
    // 外加一份 60 秒缓存的 `~/.claude.json`。用量条拆掉后没人看这三个数了，
    // **把这段一起摘掉是为了停掉那些文件读取** —— `PostToolUse` 很密，
    // 留着就是每秒钟为了没人看的数字去敲几次磁盘。
    // 怎么读仍完整留在 `UsageProbe` 里（连同测试），要接回来是一行的事。

    // MARK: - 终端里的选择题（spec 3.1）

    /// 每个 tab 当前摆着的选择题。收起态靠它在岛下方摆出选项。
    private(set) var menus: [UUID: TerminalMenu] = [:]

    /// 选项浮层在画布里的位置，由视图层量完报上来。
    /// 窗口层的命中测试是收在岛轮廓里的，得靠它给这块浮层放行。
    var menuFrame: CGRect = .zero

    /// 选中的那个 tab 现在有没有在问你。**只在收起态给** ——
    /// 展开时终端本身就摆着那个选单，再叠一层浮层是两份同样的东西。
    var pendingMenu: TerminalMenu? {
        guard state != .expanded, let id = selectedTab?.id else { return nil }
        return menus[id]
    }

    /// 终端上出现 / 消失了一道选择题。
    ///
    /// **这条通道补的是 hook 补不上的洞。** 探针实测：`AskUserQuestion` 那种
    /// 编号选单一个 hook 都不发，光靠事件岛根本不知道自己被问了话 ——
    /// 它会一直显示「在跑」，而终端其实卡在那儿等人。所以看到选单就等于
    /// 收到了一次「等你回话」，该催人就催人。
    func apply(_ menu: TerminalMenu?, to id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let had = menus[id] != nil
        menus[id] = menu

        if let menu {
            tabs[index].status = .waiting
            tabs[index].activity = menu.question
            let watching = state == .expanded && selectedTab?.id == id
            tabs[index].unread = !watching
            send(.sessionStopped)
        } else if had {
            // 答完了。状态交回给 hook —— 那边紧接着就会来 PostToolUse / Stop。
            // 这里只把「等你回话」摘掉，不擅自宣布它跑完了或者没跑完。
            if tabs[index].status == .waiting { tabs[index].status = .running }
            tabs[index].activity = nil
            send(.sessionProgress)
        }
    }

    /// 用户在岛下方点了一项。把对应的数字键打进 PTY，跟他自己在终端里按一样。
    func choose(_ option: TerminalMenu.Option, in id: SessionID) {
        guard let menu = menus[id] else { return }
        runtime?.write(menu.keystroke(for: option), to: id)
        // **不在这里清 menus。** 清不清由下一次扫描说了算：
        // 万一那一下没被接受（比如选单换了一页），岛该继续显示它，
        // 而不是自作主张地宣布问题解决了。
    }

    /// 输入框回车 / 终端外的追问，写进 PTY。
    func submitToSelected(_ text: String) {
        guard let id = selectedTabID, let runtime else { return }
        runtime.write(text + "\r", to: id)
    }

    /// 关掉一个 tab：终止进程、移除、必要时回落状态。
    func closeTab(_ id: UUID) {
        runtime?.close(id)
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.first?.id }
        persistTabs()
        send(tabs.isEmpty ? .lastSessionEnded : .sessionStopped)
    }

    /// 对一个已经结束的会话「继续上次会话」→ `claude --resume`。
    func resumeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let directory = tabs[index].directory, let runtime else { return }
        let title = tabs[index].title
        tabs.remove(at: index)
        runtime.close(id)
        startTask(in: ProjectDirectory(path: directory, lastUsed: .now, hasSessions: true),
                  instruction: "", resume: true)
        // startTask 用项目名当标题，这里把用户看惯的标题接回去。
        if let last = tabs.indices.last { tabs[last].title = title }
    }

    // MARK: - 持久化（spec 7）

    /// 只存骨架。会话内容归 `~/.claude`，岛不复制一份。
    func persistTabs() {
        guard runtime != nil else { return }
        TabStore.save(tabs.filter { $0.kind == .cli }.map {
            TabSnapshot(id: $0.id, title: $0.title, directory: $0.directory,
                        claudeSessionID: runtime?.session($0.id)?.claudeSessionID)
        })
    }

    /// 重启后把 tab 摆回来，但**不自动重开进程** ——
    /// 开机就悄悄拉起五个 `claude` 是用户没要求过的事。显示成「已结束 · 可继续」。
    private func restoreTabs() {
        let snapshots = TabStore.load()
        guard !snapshots.isEmpty, tabs.isEmpty else { return }
        tabs = snapshots.map {
            IslandTab(id: $0.id, title: $0.title, kind: .cli, status: .ended,
                      accent: Self.accent(for: $0.directory ?? $0.title),
                      directory: $0.directory, isDetached: true)
        }
        selectedTabID = tabs.first?.id
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
    ///
    /// 连未读一起置上：真实路径里权限询问带着 `demandsAttention` 过来，
    /// 那才是把岛推到 notice 的东西。调试入口不跟着置，测出来的就不是真行为。
    func debugAskOldestRunning() {
        guard let index = tabs.firstIndex(where: { $0.status == .running }) else { return }
        tabs[index].status = .waiting
        tabs[index].unread = true
        send(.sessionStopped)
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
