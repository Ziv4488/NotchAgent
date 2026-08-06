//
//  NotchHostingView.swift
//  NotchAgent
//
//  岛的画布固定是最大态尺寸（这样 SwiftUI 才能顺滑地插值变形），
//  但那意味着一块 576×430 的透明窗口压在屏幕顶部。
//  必须把命中测试收回到岛的真实轮廓里，否则透明区会把点击全吞掉。
//

import AppKit
import OSLog
import SwiftUI

// 不是 `final`：`ResizeCursorTests` 要继承它、盖住 `addCursorRect` 抄一份参数。
// AppKit 登记进去之后不给任何查询的口子，不抄就没法断言「窗口到底派了什么活下来」
// —— 而上一版光标改坏，栽的正是「测试自己调了一遍就当作数」。
class NotchHostingView: NSHostingView<IslandShell> {

    /// 岛此刻的尺寸与圆角，由窗口层注入。
    var islandGeometry: () -> (size: CGSize, radii: IslandCornerRadii) = {
        (.zero, IslandCornerRadii(bottom: 0, inverted: 0))
    }

    private let log = Logger(subsystem: "com.notchagent", category: "drop")

    required init(rootView: IslandShell) {
        super.init(rootView: rootView)
        // 往 ＋ 面板里拖 `.app`（见下面「拖放」那一节）。
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 岛不是「先点亮自己、再干活」的窗口。app 在后台时点岛的第一下就该算数，
    /// 而不是只用来把焦点拿回来（键盘那一半在 `NotchWindow.activateForClick`）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 收到的是父视图坐标系里的点。
        let local = convert(point, from: superview)
        guard accepts(local) else { return nil }
        return super.hitTest(point)
    }

    /// 这一点归不归岛管。**`hitTest` 的放行判定，单独拎出来是为了能测**
    /// —— 离屏的 `super.hitTest` 靠不靠得住是 AppKit 的事，
    /// 而这轮改坏的一直是「放不放行」这一步。
    ///
    /// 三块地方放行，其余一律穿透到下面的 app：
    ///
    /// 1. 岛的轮廓本身。
    /// 2. 挂在岛下面的选项浮层 —— 它在轮廓之外，不单独放行点上去没有任何反应。
    /// 3. 拖拽热区**探到岛外面**的那一圈（`ResizeHandles.Layout.outerReach`）。
    ///    热区 2026-08-04 改成跨在边线上，外面那 4pt 要是照旧穿透，
    ///    就成了「光标在那儿已经是缩放箭头，按下去却落到底下的窗口上」。
    ///    用的是手柄自己报上来的位置，不另算一遍：跟踪区、cursor rect、
    ///    命中测试三处口径分开算，迟早有一处对不上，而对不上的表现正是
    ///    「看着能拖，按下去没反应」。收起态没有手柄，字典是空的，这条恒为假。
    func accepts(_ pointInView: NSPoint) -> Bool {
        // **洞先判，而且是一票否决。** 它整个落在岛的轮廓里，顺序反过来的话
        // 下面那句先把它认成「岛的地盘」放行了 —— 表现就是贴附的窗口看得见、
        // 点不动，点击全被岛吃掉。
        if attachedHoleRect().contains(pointInView) { return false }
        if islandPath().contains(pointInView) || menuRect().contains(pointInView) { return true }
        return rootView.model.resizeHandleFrames.values
            .contains { !$0.isEmpty && $0.contains(pointInView) }
    }

    /// 拖拽热区的光标形状 —— **只在 macOS 14 上走这里**。
    ///
    /// 15 起交给 SwiftUI 的 `pointerStyle`（见 `ResizeHandles.usesLegacyCursorRects`
    /// 上面那段：cursor rect 只在跨边界那一下触发，被终端的 `cursorUpdate` 改掉
    /// 就回不来；而且画布在 z 序上压在终端下面，下角正好被咬掉一块）。
    /// 两套同时开着会在同一块地方互相抢，所以是二选一。
    ///
    /// 14 上仍然**登记在这儿、不登记在手柄自己身上**：试过在手柄那层塞一个
    /// `NSViewRepresentable` 去 `addCursorRect`，实机一个箭头都不出现 ——
    /// 那层为了不吞点击（§2.2b 的旧账）必须 `hitTest` 返回 nil，
    /// 而窗口找「该用哪个光标」要先命中到视图。这块画布本来就是可命中的。
    override func resetCursorRects() {
        super.resetCursorRects()
        guard ResizeHandles.usesLegacyCursorRects else { return }
        for (kind, frame) in rootView.model.resizeHandleFrames where !frame.isEmpty {
            addCursorRect(frame, cursor: kind.cursor)
        }
    }

    // MARK: - 拖放

    /// 拖放**不走 SwiftUI 的 `.dropDestination`**，在这一层用 AppKit 原生的
    /// `NSDraggingDestination` 接。
    ///
    /// 08-07 实机第一版是 `NewTaskForm` 上挂 `.dropDestination(for: URL.self)`，
    /// 用户报「拖不进去」。那条路上叠着两个各自都会坏的环节：
    ///
    /// 1. `URL` 的 `Transferable` 认的是 `public.url`，而访达送过来的是
    ///    `public.file-url`；
    /// 2. 岛是 `.nonactivatingPanel`、层级压在菜单栏之上，SwiftUI 那层收不收得到
    ///    拖拽，本来就没验过。
    ///
    /// 直接读剪贴板把第 1 条整个绕开；落在窗口层则让第 2 条变得**可观测** ——
    /// 下面每一步都记日志（`log stream --predicate 'category == "drop"'`），
    /// 要是连 `draggingEntered` 都不来，那就断定是窗口本身收不到，
    /// 而不必再猜是哪一层把它吃了。
    ///
    /// 命中测试这一关是过得去的：`hitTest` 只放行岛的轮廓，而 ＋ 面板画在轮廓里。
    private var draggedApps: [AttachableApp] = []

    /// 这一下拖拽收不收。**拆出来是为了能测** —— `NSDraggingInfo` 是协议，
    /// 造假的成本远高于把判据本身拎出来，而会写错的正是判据。
    static func welcomesDrop(inIsland: Bool, isExpanded: Bool,
                             showsNewTaskForm: Bool, hasApps: Bool) -> Bool {
        inIsland && isExpanded && showsNewTaskForm && hasApps
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = AppRegistry.fileURLs(on: sender.draggingPasteboard)
        // 认一次就存着：`draggingUpdated` 每动一下就来一发，
        // 每发都去 `Bundle(url:)` 读一遍 Info.plist 是在拖拽路径上做磁盘 IO。
        draggedApps = AppRegistry.identify(urls)
        log.info("拖进来了：\(urls.count) 个 URL，认出 \(self.draggedApps.count) 个 app")
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endDrag()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        endDrag()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = AppRegistry.fileURLs(on: sender.draggingPasteboard)
        endDrag()
        let took = rootView.model.addAppTabs(from: urls)
        log.info("松手：收下了 \(took ? "是" : "否")")
        return took
    }

    /// 指针此刻这一点该给什么操作，顺带把高亮那一位同步过去。
    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let model = rootView.model
        let welcome = Self.welcomesDrop(inIsland: islandPath().contains(point),
                                        isExpanded: model.state == .expanded,
                                        showsNewTaskForm: model.showsNewTaskForm,
                                        hasApps: !draggedApps.isEmpty)
        model.isDropTargeted = welcome
        return welcome ? .copy : []
    }

    /// 拖拽收场（松手、拖出去、被取消）都要把高亮收掉，一处也不能漏 ——
    /// 漏一处就是那圈虚线永远留在面板上。
    private func endDrag() {
        rootView.model.isDropTargeted = false
        draggedApps = []
    }

    // MARK: - 非 key 状态下的光标

    /// 已经装上去的热区。**只有真的挪了才重装。**
    ///
    /// 每次 `layout` 都重装是不行的：「指针正停在框里、把框撤掉」**不会产生
    /// `mouseExited`**，再装上时指针已经在别处，也不会有 `mouseEntered` ——
    /// 于是光标停在上一个形状上再也不还原。实测：指针从底边挪进内容区，
    /// 进出事件一次都不来，调整光标一路挂着出了岛（用户报的
    /// 「移出岛外的时候也有箭头」）。
    private var installedHandleFrames: [ResizeHandles.Kind: CGRect] = [:]
    /// 内部可见：`ResizeCursorTests` 要数「装了几块」「有没有被反复重装」。
    private(set) var handleAreas: [NSTrackingArea] = []
    /// 现在挂着的是不是我们设的那个 —— 只收自己放出去的，别去动终端的 I 型光标。
    private var showingResizeCursor = false
    /// 鼠标移动的监视器（见 `watchMouseMoves`）。
    private var moveMonitor: Any?

    /// 光标要自己设，**因为岛多数时候不是 key window**。
    ///
    /// 这是前几版都栽了的根因。AppKit 的三套光标机制（cursor rect、`.cursorUpdate`
    /// 跟踪区、SwiftUI 的 `pointerStyle`）默认**只在 key window 里生效**，
    /// 而岛是 `.nonactivatingPanel`，`canBecomeKey` 只在展开态为真、
    /// 还得用户点过它才成立。挪着真指针读 `NSCursor.currentSystem` 量出来的三格：
    ///
    /// | app | 窗口 | 热区上的光标 |
    /// |---|---|---|
    /// | 前台 | key | 对（`pointerStyle` 管着） |
    /// | 前台 | 非 key | 三套全不生效，只能自己设 —— 就是这儿 |
    /// | 后台 | — | **改不了**，系统只给普通箭头 |
    ///
    /// 靠 `mouseEntered` 一个人是不够的 —— 这是看用户录屏才发现的：进热区那一下
    /// 我们设对了，**指针还在热区里继续动，光标就被改回了普通箭头**，
    /// 而不会再有第二个 `mouseEntered`，于是那一整趟都是错的。
    /// 录屏（120fps）里量得清清楚楚：从岛外进右下角，第 7.8 秒是斜向箭头，
    /// 7.9 秒起整整一秒全是普通箭头，指针一直在热区里没出去；
    /// 反方向（从岛内往下走进热区）则一路都对 —— 用户说的「一瞬间就消失」
    /// 和「来回几次就不显示」是同一件事。所以**每次鼠标移动都得重设一遍**。
    ///
    /// **移动事件不能靠跟踪区的 `.mouseMoved` 拿**：macOS 26 上那个标志会让
    /// WindowServer 凭空合成 left-mouse-down（SwiftTerm 为此专门绕了一道，见
    /// `MacTerminalView.startTracking`），落在热区上就是「鼠标扫过去岛自己开始
    /// 缩放」。改用它那套办法：跟踪区只负责进出，移动走窗口级的本地事件监视器。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let frames = rootView.model.resizeHandleFrames.filter { !$0.value.isEmpty }
        guard frames != installedHandleFrames else { return }

        for area in handleAreas { removeTrackingArea(area) }
        handleAreas = frames.values.map {
            NSTrackingArea(rect: $0, options: [.activeAlways, .mouseEnteredAndExited],
                           owner: self, userInfo: nil)
        }
        for area in handleAreas { addTrackingArea(area) }
        installedHandleFrames = frames
        // 刚换过一批框，指针此刻在哪儿得重新算一次 —— 重装本身不产生进出事件。
        watchMouseMoves()
        refreshCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        watchMouseMoves()   // SwiftTerm 收工时会把 acceptsMouseMovedEvents 关回去
        refreshCursor()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshCursor()
    }

    /// 每次鼠标移动都把光标重设一遍 —— 不然进热区之后第一次移动就被打回箭头。
    ///
    /// `acceptsMouseMovedEvents` 是窗口级开关，终端那边也在用（它自己也会开，
    /// 收工时按开之前的值还原 —— 所以我们要在进热区时补设一次，别被它关掉）。
    /// 开着不会让终端多报什么：`TerminalView.mouseMoved` 自己会检查
    /// `terminal.mouseMode.sendMotionEvent()`，TUI 没要就不发。
    private func watchMouseMoves() {
        window?.acceptsMouseMovedEvents = true
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            // **不按 `event.window` 过滤。** 屏幕上不止一个岛时（每屏一个），
            // 同一个位置的移动事件会被派给另一块岛的窗口 —— 按窗口筛就漏掉了，
            // 于是指针还在热区里、光标却再没人管（量过：漏掉的那几步全是普通箭头）。
            // 反正 `refreshCursor` 自己按本窗口的指针位置判断，不属于自己的它不碰。
            self?.refreshCursor()
            return event   // 绝不吞：终端和别的跟踪区还要收
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
        } else {
            watchMouseMoves()
        }
    }

    deinit {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
    }

    /// 按指针**此刻**的位置定形状。
    ///
    /// 不用事件里带的坐标：`mouseExited` 给的是「离开时那一点」，常常还压在框的边上，
    /// 拿它判断会得出「还在框里」，于是永远不还原。
    private func refreshCursor() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if let kind = rootView.model.resizeHandleFrames.first(where: { $0.value.contains(point) })?.key {
            kind.cursor.set()
            showingResizeCursor = true
        } else if showingResizeCursor {
            NSCursor.arrow.set()
            showingResizeCursor = false
        }
    }

    /// 岛一变形热区就挪位置，登记过的矩形当场过期。
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    /// 岛给贴附窗口挖的那个洞，转换到本视图坐标系。没贴东西时是空矩形。
    ///
    /// **和 `islandPath()` 走完全相同的那一下换算**（同样的 `originX`、
    /// 同样按 `isFlipped` 分两支）—— 洞是画在岛体上的，两边各算一套的话
    /// 迟早差出几个点，而差出来的表现是「窗口边上一条缝点不动」。
    func attachedHoleRect() -> CGRect {
        let hole = rootView.model.attachedHoleInIsland
        guard !hole.isEmpty else { return .null }

        let (size, radii) = islandGeometry()
        let originX = bounds.midX - (size.width + radii.inverted * 2) / 2
        guard isFlipped else {
            return CGRect(x: originX + hole.minX, y: bounds.maxY - hole.maxY,
                          width: hole.width, height: hole.height)
        }
        return hole.offsetBy(dx: originX, dy: bounds.minY)
    }

    /// 选项浮层占的那块。没有浮层时是空矩形，`contains` 恒为假。
    private func menuRect() -> CGRect {
        let frame = rootView.model.menuFrame
        return frame.isEmpty ? .null : frame
    }

    /// 岛的轮廓，转换到本视图坐标系。
    ///
    /// `NSHostingView` 是 flipped 的（y 朝下），和 SwiftUI `Path` 一致，正常情况下
    /// 只要平移。但 `isFlipped` 不是本类的承诺，所以两种约定都处理，别赌。
    func islandPath() -> Path {
        let (size, radii) = islandGeometry()
        guard size.width > 0, size.height > 0 else { return Path() }

        let canvasWidth = size.width + radii.inverted * 2
        // 岛贴在画布顶部、水平居中。
        let originX = bounds.midX - canvasWidth / 2

        let shape = NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: canvasWidth, height: size.height))

        guard isFlipped else {
            // y 朝上：先竖直翻转，再平移到画布顶部。
            return path
                .applying(CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -size.height))
                .applying(CGAffineTransform(translationX: originX, y: bounds.maxY - size.height))
        }
        return path.applying(CGAffineTransform(translationX: originX, y: bounds.minY))
    }
}
