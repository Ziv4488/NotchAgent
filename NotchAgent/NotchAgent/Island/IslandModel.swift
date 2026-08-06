//
//  IslandModel.swift
//  NotchAgent
//
//  岛的可观察状态。第 1 阶段全部由假数据 + 调试菜单驱动，
//  第 2 阶段把 tabs 换成真实会话、把事件源换成 StatusFeed。
//

import SwiftUI
import Observation

/// 用量与模式这一整块 **2026-08-02 全删了**，这里只留一句交代。
///
/// 8/1 先删的是三项额度（上下文 / 5 小时 / 周）和读它们的 `UsageProbe`：
/// 终端里 Claude Code 自己那条 statusline 就写着，岛再抄一遍是同一份信息占两行。
/// 剩下的 `mode`（权限档位）和 `subagents`（子代理数）当时留了下来 —— hook 一直在
/// 解析、一直往 tab 上写，**界面上一个都不画**。活着的解析配死掉的展示，
/// 还有六条测试守着一份没人看的数据。8/2 用户拍板一起删。
///
/// 要找当初查证过的事实（`permission_mode` 的四个内部标识、`Task` 工具的起止
/// 对应子代理的增减）去翻 git。

/// tab 的一格。第 2 阶段会被 `SessionKit` 的真实会话替换。
struct IslandTab: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Claude Code CLI 会话，岛内原生渲染终端。
        case cli
        /// 第三方 app，真实窗口贴附在岛下方。
        ///
        /// **bundle id 就是它全部的身份。** app tab 不是会话（08-06 拍板）：
        /// 输入、焦点、内容全归原 app，岛这边不转发任何东西，所以它既不进
        /// `SessionStore` 也不实现 `AgentSession` —— 那套抽象里的
        /// `start`/`write`/`resize`/`terminate` 对贴附一个窗口没有一个是成立的。
        case app(bundleID: String)
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
    /// 工作目录。重启恢复和「继续上次会话」都要它。
    var directory: String?
    /// 收起态状态带上那行字：「读 session.ts」。由 hook 事件驱动，
    /// 没有事件时是 nil，状态带退回显示项目名。
    var activity: String?
    /// 进程已经退出（正常或异常），只能「继续上次会话」重开。
    var isDetached: Bool
    /// 退出得**不正常**：非零退出码，或者进程中途崩了。
    ///
    /// 和 `isDetached` 分开：那个只说「进程没了」，正常 `/exit` 也是它。
    /// 内容区要区别对待 —— 正常结束是一句平静的交代，异常退出得说清楚
    /// 到底发生了什么（退出码在 `activity` 里），不然用户只看到一块黑。
    var endedAbnormally: Bool

    init(id: UUID = UUID(), title: String, kind: Kind, status: Status,
         unread: Bool = false, accent: Color,
         startedAt: Date = .now,
         directory: String? = nil, activity: String? = nil, isDetached: Bool = false,
         endedAbnormally: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.unread = unread
        self.accent = accent
        self.startedAt = startedAt
        self.directory = directory
        self.activity = activity
        self.isDetached = isDetached
        self.endedAbnormally = endedAbnormally
    }

    /// 这是个贴附第三方 app 的 tab 吗。
    var isApp: Bool { appBundleID != nil }

    /// 贴附目标的 bundle id，CLI tab 是 nil。
    var appBundleID: String? {
        if case .app(let bundleID) = kind { bundleID } else { nil }
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
    ///
    /// 撑不下的时候由 `IslandMetrics` 封顶在展开宽度，多出来的 tab 归 tab 条
    /// 自己横向滚动（见 `TabStrip.body`）—— 岛不会为了装下第九个 tab 而横跨整块屏幕。
    var tabStripWidth: CGFloat {
        TabStrip.measuredWidth(for: tabs, hookDegraded: hookChannelDegraded)
    }

    /// 岛的外形里跟 tab 有关的那一部分：**几个、多宽**。
    ///
    /// 岛的形变动画挂在它上面而不是挂在 `tabs` 上 —— 拖着 tab 换位置时
    /// `tabs` 变了但外形没变，挂错了整条 tab 条会跟着弹簧一颠一颠（见 `IslandShell`）。
    /// 两个字段都与顺序无关：个数是个数，宽度是各芯片宽度之和。
    struct TabShape: Equatable {
        var count: Int
        var width: CGFloat
    }

    var tabShape: TabShape { TabShape(count: tabs.count, width: tabStripWidth) }

    var size: CGSize {
        metrics.size(for: state, tabStripWidth: tabStripWidth, chromeOnly: selectedTabIsApp)
    }

    /// 选中的是个贴附第三方 app 的 tab 吗。岛为它缩成只剩 chrome。
    var selectedTabIsApp: Bool { selectedTab?.isApp == true }

    // MARK: - 贴附第三方 app（spec 6）

    /// 贴附那一层。**nil 就是不接** —— 预览和单测默认不去碰真窗口。
    var attach: AttachDriver?

    /// 贴附出岔子了。内容区拿它画占位卡（没授权时引导去系统设置）。
    private(set) var attachFailure: AttachFailure?

    /// 目标窗口压不下去的那个尺寸。
    ///
    /// spec 6.4 原本写的是「压不住就把岛加宽」，那是事后补救；实测下来更干净的
    /// 做法是**反过来钉住拖拽下限** —— 根本不让用户拖到窗口做不到的尺寸去。
    /// 这个数问不出来，只能设完读回（spec 11.4），所以它来自 attach 的返回值。
    private(set) var attachedMinimum: CGSize?

    /// 让贴附跟上「现在选中谁、岛是什么形态」。
    ///
    /// 切走、收起只**藏**不还原（`hide` 等价 ⌘H，spec 6.2）：还原是把窗口放回
    /// 用户原来摆的地方，那属于「不玩了」，只在移除 tab 和退出时做。切来切去
    /// 每次都还原一遍的话，窗口会在屏幕上来回蹦。
    func syncAttachment() {
        guard let attach else { return }
        let active = state == .expanded ? selectedTab?.appBundleID : nil

        // 除了当前这个，其余贴过的都收起来。
        for bundleID in Set(tabs.compactMap(\.appBundleID)) where bundleID != active {
            attach.hide(bundleID: bundleID)
        }

        guard let active else {
            attach.cancelPendingFollows()
            return
        }
        attach.unhide(bundleID: active)
        attach.attach(bundleID: active, to: metrics.contentRectOnScreen) { [weak self] result in
            self?.apply(result)
        }
    }

    private func apply(_ result: Result<CGRect, AttachFailure>) {
        switch result {
        case .success(let achieved):
            attachFailure = nil
            // **只有真的被钳住才记。** 实得等于要的，说明窗口压得下去，
            // 这时候把当前尺寸当成下限的话，用户就再也拖不小了。
            // 两个方向分开判：只钳宽不钳高是常事。
            let asked = metrics.contentRectOnScreen
            let width = achieved.width > asked.width + 0.5 ? achieved.width : 0
            let height = achieved.height > asked.height + 0.5 ? achieved.height : 0
            attachedMinimum = (width > 0 || height > 0)
                ? CGSize(width: width, height: height) : nil
        case .failure(let failure):
            attachFailure = failure
            attachedMinimum = nil
        }
    }

    /// 把拖进来的 `.app` 变成 tab（用户 08-07 定的入口）。
    ///
    /// 返回真表示收下了 —— 拖放的 API 靠这个决定要不要播那个「飞回去」的动画。
    ///
    /// **同一个 app 已经有 tab 了就选中它，不再建一个。** 两个 tab 指着同一个
    /// bundle id 会互相抢那一个窗口：切到 A 贴上，切到 B 又贴一遍，
    /// 而 B 记的「原始 frame」是 A 贴完之后的样子 —— 窗口从此回不去了。
    @discardableResult
    func addAppTabs(from urls: [URL]) -> Bool {
        let apps = AppRegistry.identify(urls)
        guard !apps.isEmpty else { return false }

        for app in apps {
            if let existing = tabs.first(where: { $0.appBundleID == app.bundleID }) {
                selectedTabID = existing.id
                continue
            }
            let tab = IslandTab(title: app.name, kind: .app(bundleID: app.bundleID),
                                status: .done, accent: Self.accent(for: app.bundleID))
            tabs.append(tab)
            selectedTabID = tab.id
        }
        isComposingNewTask = false
        persistTabs()
        send(.sessionStarted)
        // `send` 只在状态**真的变了**时才同步；已经展开着的话得自己补一次。
        syncAttachment()
        return true
    }

    /// 拖拽时把新矩形喂给贴附的窗口。合并由 `AttachDriver` 管。
    private func followAttachment() {
        guard let attach, state == .expanded,
              let bundleID = selectedTab?.appBundleID else { return }
        attach.follow(metrics.contentRectOnScreen, bundleID: bundleID)
    }

    /// 岛的圆角。**底下挂着选项浮层时，底边是接缝，圆角要收掉。**
    ///
    /// 留着圆角的话接缝两侧会各露一个小缺口；用浮层的背景往上盖住那两块，
    /// 又会把 tab 条的下沿一起盖掉（用户报的「选项盖住通知态一点」）。
    /// 让岛把圆角让出来、由浮层去圆最底下那两个角，两边都不用互相压。
    var cornerRadii: IslandCornerRadii {
        var radii = metrics.cornerRadii(for: state)
        if pendingMenu != nil { radii.bottom = 0 }
        return radii
    }

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
        // 展开/收起都会改变「窗口该不该露出来」。
        syncAttachment()
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

    /// 拖拽范围。**选中 app tab 时下限被那个窗口的最小尺寸顶起来**（spec 6.4）：
    /// 目标窗口压不到岛这么小，与其让它溢出去错位，不如根本不让用户拖到那儿。
    var expandedWidthRange: ClosedRange<CGFloat> {
        raise(metrics.expandedWidthRange, to: attachedMinimum?.width)
    }

    var expandedContentHeightRange: ClosedRange<CGFloat> {
        // 贴附的窗口占的是「内容区 + 退休的输入框那 44pt」，换算回内容区口径。
        let floor = attachedMinimum.map { $0.height - constants.retiredInputBarHeight }
        return raise(metrics.expandedContentHeightRange, to: floor)
    }

    private func raise(_ range: ClosedRange<CGFloat>, to floor: CGFloat?) -> ClosedRange<CGFloat> {
        guard let floor, floor > range.lowerBound else { return range }
        return floor...Swift.max(floor, range.upperBound)
    }

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
        followAttachment()
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
        // `send` 只在状态**真的变了**的时候才走到 syncAttachment，
        // 而 tab 之间互切通常不改变状态（一直是 expanded）。这里补一次。
        syncAttachment()
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

    /// 把一个 tab 拖到另一个位置。
    ///
    /// **不落盘**：拖动过程中这个方法一格一格地被调，每格存一次是白敲磁盘。
    /// 手松开时由视图层调 `persistTabs()`（见 `TabStrip.drag`）。
    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination),
              source != destination else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
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
    /// - Parameter at: 新 tab 插在第几位。默认追加到末尾；「继续上次会话」
    ///   传原来那一位，好让它待在用户排好的地方（见 `resumeTab`）。
    func startTask(in project: ProjectDirectory, instruction: String,
                   resume: Bool = false, at insertion: Int? = nil) {
        guard let runtime else {
            // 没有 runtime 只会出现在预览和单元测试里。
            isComposingNewTask = false
            debugStartSession(named: project.name, directory: project.path)
            let new = tabs.last?.id
            if let insertion, let last = tabs.indices.last { moveTab(from: last, to: insertion) }
            selectedTabID = new
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
        tabs.insert(tab, at: min(insertion ?? tabs.count, tabs.count))
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

    /// hook 通道没连上。见 `SessionRuntime.hookChannelFailure`。
    ///
    /// 在 `attach` 时抄进来一份而不是每次去问 `runtime` —— 那个字段不是
    /// `@Observable` 的，视图读它不会建立依赖，改了也不会重画。
    /// 通道的成败在 `runtime.start()` 里一次定死（`attach` 之后不再变），
    /// 抄一份反而是最诚实的表达。
    private(set) var hookChannelDegraded = false

    func attach(runtime: SessionRuntime) {
        self.runtime = runtime
        hookChannelDegraded = runtime.hookChannelFailure != nil
        runtime.onSignal = { [weak self] id, signal in self?.apply(signal, to: id) }
        runtime.onStatusChanged = { [weak self] id, status in self?.apply(status, to: id) }
        runtime.onMenu = { [weak self] id, menu in self?.apply(menu, to: id) }
        runtime.onTurnCancelled = { [weak self] id in self?.cancelTurn(id) }
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
    ///
    /// **非零退出要说出退出码。** 原来这里只有 `.failed` 会留下文案，
    /// `.finished(1)` 和 `.finished(0)` 落到界面上是同一句「会话已结束。」——
    /// claude 崩了、被 OOM 杀了、参数写错了当场退出，用户看到的都一样，
    /// 而这三种情况该做的事完全不同。
    func apply(_ status: SessionStatus, to id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch status {
        case .finished, .failed:
            tabs[index].status = .ended
            tabs[index].isDetached = true
            tabs[index].activity = Self.endNote(for: status)
            tabs[index].endedAbnormally = Self.isAbnormal(status)
            send(.sessionStopped)
            persistTabs()
        default:
            tabs[index].status = IslandTab.Status(status)
        }
    }

    /// 会话结束时，内容区上那一句话。正常结束是 nil（走默认文案）。
    ///
    /// 退出码按 shell 的惯例读：128 以上是被信号杀的，减掉 128 就是信号号
    /// （`SessionStatus.fromWaitStatus` 就是这么编的）。直接把 143 甩给用户
    /// 没有意义，说「被终止（SIGTERM）」他才知道不是自己的代码有问题。
    static func endNote(for status: SessionStatus) -> String? {
        switch status {
        case .failed(let reason):
            return reason
        case .finished(let code) where code == 0:
            return nil
        case .finished(let code) where code > 128:
            return "会话被终止（信号 \(code - 128)）。"
        case .finished(let code):
            return "会话异常退出，退出码 \(code)。"
        default:
            return nil
        }
    }

    static func isAbnormal(_ status: SessionStatus) -> Bool {
        switch status {
        case .failed: true
        case .finished(let code): code != 0
        default: false
        }
    }

    // MARK: - 终端里的选择题（spec 3.1）

    /// 每个 tab 当前摆着的选择题。收起态靠它在岛下方摆出选项。
    private(set) var menus: [UUID: TerminalMenu] = [:]

    /// 选项浮层在画布里的位置，由视图层量完报上来。
    /// 窗口层的命中测试是收在岛轮廓里的，得靠它给这块浮层放行。
    var menuFrame: CGRect = .zero

    /// 五块拖拽热区在画布里的位置，同样由视图层量完报上来。
    /// `NotchHostingView` 拿它去登记 cursor rect（光标形状），见那边的注释。
    var resizeHandleFrames: [ResizeHandles.Kind: CGRect] = [:]

    /// 正拖着一个 `.app` 悬在岛上。＋ 面板据此画那圈虚线（`NewTaskForm.dropHint`）。
    ///
    /// **这一位由窗口层写，不是 SwiftUI 写的。** 拖放走的是
    /// `NotchHostingView` 上的 `NSDraggingDestination`，理由见那边。
    var isDropTargeted = false

    /// 选中的那个 tab 现在有没有在问你。**只在收起态给** ——
    /// 展开时终端本身就摆着那个选单，再叠一层浮层是两份同样的东西。
    var pendingMenu: TerminalMenu? {
        guard state != .expanded, let id = selectedTab?.id else { return nil }
        return menus[id]
    }

    /// 浮层现在摆的是个输入框，而不是一排选项。
    ///
    /// 窗口层靠它决定收起态能不能拿键盘（`NotchWindow.canBecomeKey`）——
    /// 平时收起态是拿不了的，那正是「点了 Type something. 之后打字没反应」的原因。
    var wantsInlineTextEntry: Bool { pendingMenu?.wantsTextEntry == true }

    /// 收起态的输入框用完了，键盘该还回去。窗口层接。
    var onInlineEntryEnded: (() -> Void)?
    /// 收起态的输入框被点了，把键盘拿过来。窗口层接。
    var onInlineEntryFocusRequested: (() -> Void)?

    /// 终端上出现 / 消失了一道选择题。
    ///
    /// **这条通道补的是 hook 补不上的洞。** 探针实测：`AskUserQuestion` 只发
    /// `PreToolUse`，**不发 `Notification`** —— 也就是没有任何事件说「它停下来等你了」。
    /// 光靠 hook，岛会一直显示「在跑」，而终端其实卡在那儿等人。
    /// 所以看到选单就等于收到了一次「等你回话」，该催人就催人。
    func apply(_ menu: TerminalMenu?, to id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let had = menus[id] != nil
        let hadTextEntry = menus[id]?.wantsTextEntry == true
        menus[id] = menu
        // 那个输入框没了，键盘就该还给用户原来在用的 app —— 收起态的岛
        // 只在「有个框在等他打字」的时候才占着键盘。
        if hadTextEntry, menu?.wantsTextEntry != true { onInlineEntryEnded?() }

        if let menu {
            tabs[index].status = .waiting
            tabs[index].activity = menu.wantsTextEntry ? "等你打字" : menu.question

            // 终端在等一段自由输入（用户选了「Type something.」那一类）。
            //
            // 上一版是把岛**展开**：收起态窗口成不了 key，打字没反应，
            // 再点别的选项，数字全打进了那个输入框。展开确实能用，但用户不要 ——
            // 「不能不打开在直接在上面输入吗」。现在浮层自己变成一个输入框，
            // 窗口在这段时间里允许成为 key（`wantsInlineTextEntry`），
            // 用户点一下那个框就能打字，回车把整段送进 PTY。
            let watching = state == .expanded && selectedTab?.id == id
            tabs[index].unread = !watching
            // 收起时选它。浮层只摆选中那个 tab 的题（岛下面只有一块地方），
            // 别的 tab 在问话就得先切过去 —— 让用户自己去找是把「谁在问」
            // 这件已经知道的事又推回给他。
            //
            // **展开时不切。** 那时候用户正看着某个 tab 的终端，
            // 底下换成另一个会话，是把他从他手上的事情里拽走。
            if state != .expanded { selectedTabID = id }
            send(.sessionStopped)
        } else if had {
            // 答完了。状态交回给 hook —— 那边紧接着就会来 PostToolUse / Stop。
            // 这里只把「等你回话」摘掉，不擅自宣布它跑完了或者没跑完。
            if tabs[index].status == .waiting { tabs[index].status = .running }
            tabs[index].activity = nil
            send(.sessionProgress)
        }
    }

    /// 用户按 Esc 把这一轮掐了。
    ///
    /// **这条路上没有别的信号。** 探针实测（`scripts/spike-escape.py`）：选单出现后
    /// 按 Esc，`PostToolUse`、`Stop` 一条都不来，等 25 秒也没有。而选单一消失，
    /// `apply(nil,to:)` 会按「答完了」把状态交回 `.running` —— 于是那个 tab
    /// 永远琥珀色慢呼吸、计时一路往上涨。用户报的就是这个。
    ///
    /// 所以这里要**赶在扫描之前**把选单从记录里摘掉：`apply(nil,to:)` 只在
    /// 「本来有」的时候才动状态，先摘掉，那一拍就成了空操作。
    ///
    /// 状态给 `.done` 而不是 `.ended`：会话还活着，只是这一轮没了。
    func cancelTurn(_ id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        menus[id] = nil
        tabs[index].status = .done
        tabs[index].activity = nil
        // 是他自己按的 Esc，人就在跟前，不该再标一条未读回头催他。
        tabs[index].unread = false
        // **不是 `.sessionStopped`。** 那个事件一律弹 notice（「完成了，去看一眼」），
        // 可这一轮是用户自己掐的，他刚看过 —— 弹出来催他去看他自己做的事，
        // 正是那个「一直挂着通知态」的老毛病。这里只要重算形态。
        send(.sessionProgress)
    }

    /// 用户在岛下方点了一项。把对应的数字键打进 PTY，跟他自己在终端里按一样。
    func choose(_ option: TerminalMenu.Option, in id: SessionID) {
        guard let menu = menus[id] else { return }
        runtime?.write(menu.keystroke(for: option), to: id)
        // **不在这里清 menus。** 清不清由下一次扫描说了算：
        // 万一那一下没被接受（比如选单换了一页），岛该继续显示它，
        // 而不是自作主张地宣布问题解决了。
        markAnsweredOnIsland(id)
    }

    /// 用户**在岛上**把这道题答了。
    ///
    /// 未读那一条是「有人在等你回话，回头去看一眼」。他刚刚就在跟前、
    /// 亲手答完了，再留着未读就是催他去看他自己做过的事 ——
    /// 表现是浮层收掉之后岛停在通知态不肯收起。用户报的就是这个：
    /// 「输入完后只会进入通知态，没有完全收起，包括选择也是」。
    ///
    /// 只清未读，**不碰 status**：这一轮跑没跑完由 hook 说了算，
    /// 岛不擅自宣布（同 `apply(nil,to:)` 里那段）。
    private func markAnsweredOnIsland(_ id: SessionID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].unread = false
        send(.sessionProgress)
    }

    /// 收起态那个输入框回车：整段打进 PTY，然后把键盘还回去。
    ///
    /// **整段一次性发，不是逐字发。** 逐字发看起来更像真终端，但中文输入法
    /// 组字期间的每一下都会被当成正文送出去。岛上这个框和真终端的差别只有
    /// 「字先攒在岛上」这一处，回车之后终端收到的字节和他自己敲的一模一样。
    func submitInlineText(_ text: String) {
        guard let id = selectedTab?.id else { return }
        runtime?.write(text, to: id)
        // **回车必须单独发，而且要隔开一点。**
        //
        // 实机验过两次：`"noodles\r"` 一次写进去，终端收到的是
        // `→ __other__`（空的自定义回答），正文整段丢了 —— Claude Code 的 TUI
        // 是 Ink 写的，它把一次 stdin chunk 当成**一次按键**，末尾带 `\r`
        // 的那一整块就只被当成一下回车。
        //
        // 分两次写、中间隔 80ms，正文先进框，回车再提交，和人手打是一样的。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.runtime?.write("\r", to: id)
        }
        // 不在这里清 menus：清不清由下一次扫描说了算（同 `choose`）。
        // 但键盘现在就该还 —— 他已经答完了。
        onInlineEntryEnded?()
        markAnsweredOnIsland(id)
    }

    /// 从输入框**退回选项列表**。
    ///
    /// 发一下 ↑ —— 光标离开「Type something.」那一行，终端也就不再是输入态，
    /// 下一拍扫描把选项重新报上来，浮层自己变回一排按钮。
    ///
    /// **不能用 Esc 代替**：那是「整道题取消」（屏幕上印着 Esc to cancel），
    /// 用户要的只是「我不想自己打字了，还是从给的选项里挑」。
    func backOutOfTextEntry() {
        guard let id = selectedTab?.id else { return }
        runtime?.sendCursorUp(to: id)
        // 键盘还回去：接下来是一排按钮，用不着它。
        onInlineEntryEnded?()
    }

    /// 收起态那个输入框按了 Esc：原样发给终端。
    ///
    /// 屏幕上印着「Esc to cancel」，岛不能在中间把它拦掉变成别的意思 ——
    /// 和展开态放行 Esc 是同一条规矩（见 `IslandWindowController.action`）。
    func cancelInlineText() {
        guard let id = selectedTab?.id else { return }
        runtime?.write("\u{1b}", to: id)
        onInlineEntryEnded?()
        // 取消也是「他答完了」的一种 —— 人就在跟前，别再留一条未读催他。
        markAnsweredOnIsland(id)
    }

    /// 这个 tab 背后有没有一个活着的会话进程。
    func hasLiveSession(_ id: UUID) -> Bool {
        runtime?.session(id)?.status.isAlive ?? false
    }

    /// 关一个**还活着**的 tab 之前先问一声。返回 false 就不关。
    ///
    /// 由 app 层接上真正的弹框（岛没有主窗口，弹框还得让岛先下去，
    /// 见 `NotchWindow.steppingAside`）。没接的时候 —— 预览、单测 —— 当作确认。
    var confirmCloseLiveTab: ((IslandTab) -> Bool)?

    /// 关掉一个 tab：终止进程、移除、必要时回落状态。
    ///
    /// **进程还在跑就得先问。** 关 tab 和退整个 app 是同一件事的两个尺度：
    /// 那一下点下去，一个正在干活的 Claude Code 会话就没了，跑到一半的那一轮丢掉。
    /// 退 app 早就有确认框，关 tab 没有，是漏的。
    /// 已经结束的 tab（`--resume` 接得回去的那种）不问，那一下没有代价。
    func closeTab(_ id: UUID) {
        if hasLiveSession(id), let tab = tabs.first(where: { $0.id == id }),
           confirmCloseLiveTab?(tab) == false {
            return
        }
        // **移除 app tab 就是「不玩了」，窗口必须回到原位**（spec 6.3）——
        // 挪的是别人的窗口，岛只是暂借。
        if let bundleID = tabs.first(where: { $0.id == id })?.appBundleID {
            attach?.restore(bundleID: bundleID)
        }
        runtime?.close(id)
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.first?.id }
        persistTabs()
        send(tabs.isEmpty ? .lastSessionEnded : .sessionStopped)
    }

    /// 对一个已经结束的会话「继续上次会话」→ `claude --resume`。
    func resumeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let directory = tabs[index].directory else { return }
        let title = tabs[index].title
        let count = tabs.count
        tabs.remove(at: index)
        runtime?.close(id)
        // **插回原来那一位。** 早先是直接追加，于是一个开在最左边的老 tab
        // 只要「继续上次会话」一次就窜到最右边去了（用户报的）。
        // 顺序是他自己排的，重开一次不该把它打乱。
        startTask(in: ProjectDirectory(path: directory, lastUsed: .now, hasSessions: true),
                  instruction: "", resume: true, at: index)
        // 起不来的话（找不到 claude 之类）什么都没插进来 —— 那就别去改别人的名字。
        guard tabs.count == count, tabs.indices.contains(index) else { return }
        // startTask 用项目名当标题，这里把用户看惯的标题接回去。
        tabs[index].title = title
        persistTabs()
    }

    // MARK: - 持久化（spec 7）

    /// tab 骨架存在哪。单测指到临时文件上去，别写用户真的那份。
    var tabStoreURL: URL = TabStore.fileURL

    /// 只存骨架。会话内容归 `~/.claude`，岛不复制一份。
    ///
    /// **app tab 从 08-07 起也存了。** 之前是 `filter { $0.kind == .cli }` 直接
    /// 扔掉 —— 那时 app tab 只是个调试用的假壳，没有身份可存。现在它带着
    /// bundle id，重启后能原样摆回来。
    func persistTabs() {
        guard runtime != nil else { return }
        TabStore.save(tabs.map {
            TabSnapshot(id: $0.id, title: $0.title, directory: $0.directory,
                        claudeSessionID: runtime?.session($0.id)?.claudeSessionID,
                        appBundleID: $0.appBundleID)
        }, to: tabStoreURL)
    }

    /// 重启后把 tab 摆回来，但**不自动重开进程** ——
    /// 开机就悄悄拉起五个 `claude` 是用户没要求过的事。显示成「已结束 · 可继续」。
    private func restoreTabs() {
        let snapshots = TabStore.load(from: tabStoreURL)
        guard !snapshots.isEmpty, tabs.isEmpty else { return }
        tabs = snapshots.map {
            // app tab 没有进程可言，**不该显示成「已结束 · 可继续」** ——
            // 那句话说的是「进程没了，--resume 接得回去」，对贴附毫无意义。
            // 它就是静静地摆在那儿，点一下才去接管窗口。
            if let bundleID = $0.appBundleID {
                return IslandTab(id: $0.id, title: $0.title,
                                 kind: .app(bundleID: bundleID), status: .done,
                                 accent: Self.accent(for: bundleID))
            }
            return IslandTab(id: $0.id, title: $0.title, kind: .cli, status: .ended,
                             accent: Self.accent(for: $0.directory ?? $0.title),
                             directory: $0.directory, isDetached: true)
        }
        selectedTabID = tabs.first?.id
    }

    // MARK: - 第 1 阶段的调试入口

    /// 造一个在跑的假会话。
    func debugStartSession(named name: String, directory: String? = nil) {
        let tab = IslandTab(title: name, kind: .cli, status: .running,
                            accent: Color(red: 0.85, green: 0.47, blue: 0.34),
                            directory: directory)
        tabs.append(tab)
        if selectedTabID == nil { selectedTabID = tab.id }
        send(.sessionStarted)
    }

    /// 造一个贴附的假第三方 app tab。
    func debugAttachApp(named name: String, bundleID: String = "com.openai.codex") {
        let tab = IslandTab(title: name, kind: .app(bundleID: bundleID), status: .running,
                            accent: Color(red: 0.06, green: 0.64, blue: 0.50))
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
