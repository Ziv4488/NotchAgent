//
//  IslandShell.swift
//  NotchAgent
//
//  岛的渲染入口。四态共用一套结构，靠 spring 同时插值宽、高、圆角。
//

import SwiftUI

struct IslandShell: View {
    @Bindable var model: IslandModel

    /// 报告浮层位置用的坐标系。原点就是画布左上角，和 `NotchHostingView` 的一致。
    static let canvas = "island-canvas"

    private var size: CGSize { model.size }
    private var radii: IslandCornerRadii { model.cornerRadii }
    /// 内凹圆弧画在主体两侧之外，所以整块画布比主体宽 2×inverted。
    private var canvasWidth: CGFloat { size.width + radii.inverted * 2 }

    var body: some View {
        // spacing 0：浮层贴着岛的底边长出来。中间留缝会露出桌面，
        // 读起来就成了两样东西（用户报过一次「选项跟岛隔开了」）。
        VStack(spacing: 0) {
            island
            // 终端在问话时，选项直接挂在岛下面点（spec 3.1）。
            // 窗口本来就按最大态尺寸开着（见 IslandMetrics.containerFrame），
            // 收起态下面这一大片是空的，正好放它。
            if let menu = model.pendingMenu, let id = model.selectedTab?.id {
                // 底部圆角由浮层来圆 —— 岛这时候把自己的收成了 0（接缝要平）。
                MenuPanel(menu: menu,
                          width: size.width,
                          bottomRadius: model.constants.bottomCornerRadius,
                          onChoose: { model.choose($0, in: id) },
                          onSubmit: model.submitInlineText,
                          onFocusRequest: { model.onInlineEntryFocusRequested?() },
                          onCancel: model.cancelInlineText,
                          onBack: model.backOutOfTextEntry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    // 命中测试被收在岛的轮廓里（见 NotchHostingView），
                    // 这块浮层在轮廓之外 —— 不把它的位置报上去，点了没反应。
                    //
                    // **不用 PreferenceKey。** 试过：`.background` 里的
                    // `preference(key:value:)` 一路上传不到 `onPreferenceChange`，
                    // `model.menuFrame` 从头到尾是 `.zero`，于是命中测试一律拒绝 ——
                    // 用户报的「选项点不动」就是这么来的。这里改成量完直接写。
                    .background {
                        GeometryReader { proxy in
                            let frame = proxy.frame(in: .named(Self.canvas))
                            Color.clear
                                .onAppear { model.menuFrame = frame }
                                .onChange(of: frame) { _, new in model.menuFrame = new }
                                .onDisappear { model.menuFrame = .zero }
                        }
                    }
            }
        }
        // 画布固定为最大态尺寸，岛在里面变形 —— 每帧改 NSWindow 的 frame 会抖。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 名字必须挂在**铺满画布**的那一层。挂在里面的 VStack 上，
        // 原点会是 VStack 的左上角 —— VStack 只有岛那么宽、在画布里居中，
        // 报上去的 x 就比真实位置小了半个画布。
        .coordinateSpace(name: Self.canvas)
        .animation(IslandTheme.morph, value: model.state)
        // **不是 `value: model.tabs`。** 那样一来「拖着 tab 换位置」也算 tabs 变了，
        // 整条 tab 条会跟着弹 0.38 秒的簧 —— 手还在往前走，芯片在后面一颠一颠地追，
        // 就是用户报的「拖动的时候会抽动，不跟手」。
        //
        // 岛的外形只跟**有几个 tab、tab 条有多宽**有关，跟顺序无关；换位不改变它，
        // 于是拖动一路上没有任何隐式动画，芯片的位移直接跟手。
        .animation(IslandTheme.morph, value: model.tabShape)
        .animation(IslandTheme.morph, value: model.pendingMenu)
    }

    private var island: some View {
        content
            .frame(width: canvasWidth, height: size.height, alignment: .top)
            .background { edges }
            // 只有轮廓内才吃鼠标事件，画布其余部分让点击穿透到下面的 app。
            .contentShape(NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted))
            .onHover { model.isHovering = $0 }
            .onTapGesture {
                if model.state != .expanded { model.send(.click) }
            }
            .overlay(alignment: .top) {
                if model.state == .expanded {
                    // 上沿只空出内凹圆弧那一段（8pt），不是整条状态带 ——
                    // 空整条的话竖边上面一大截摸不着（见 `ResizeHandles.topInset`）。
                    ResizeHandles(model: model,
                                  islandSize: size,
                                  topInset: radii.inverted)
                }
            }
    }

    /// 岛的外沿画不画。
    ///
    /// **idle 态不画。** 那时候岛就是刘海本身（宽只比刘海多两侧各 80pt，高正好
    /// 一条菜单栏），沿着它描一圈亮线再挂一层阴影，读起来是「屏幕顶上浮着一根
    /// 黑条」，而不是刘海。外沿是给**从菜单栏长出来的那部分**用的 ——
    /// 岛一旦探到桌面上，它就需要一条边把自己和壁纸分开。
    ///
    /// 用户 2026-08-04 的原话：「ideal 态的时候按照之前的边缘方案」，
    /// 也就是回到 08-02 那版：纯黑一块，什么都不加。
    private var showsEdges: Bool { model.state != .idle }

    /// 岛体 + 外沿三层。参数与来历见 `IslandTheme` 的「岛的外沿」。
    ///
    /// **两条线都用 `stroke` 描在轮廓上，靠线宽的一半落在里、一半落在外。**
    /// `NotchShape` 不是 `InsettableShape`，没有 `strokeBorder`；而给它加一个
    /// 内缩参数并不是把三个半径各减去一个数就完事 —— 上沿那两段内凹圆弧是
    /// 向外凸的，轮廓往里缩的时候它的半径要**变大**。为一条 0.5pt 的线去写
    /// 那套偏移几何不值当，描在轮廓上再裁一刀是等价的。
    ///
    /// **描的是 `closesTop: false` 那条开放轮廓**，顶边不描（见 `NotchShape`）。
    /// 填充仍然用闭合的那条 —— 两者填出来一模一样，但不能拿开放的去 `clipShape`
    /// 之外的地方图省事，语义上闭合与否只在描边时才成立。
    private var edges: some View {
        let shape = NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
        let outline = NotchShape(bottomRadius: radii.bottom,
                                 invertedRadius: radii.inverted,
                                 closesTop: false)
        let body = IslandBody(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
        return body
            .fill(.black, style: FillStyle(eoFill: true))
            .overlay {
                body.fill(model.isHovering && model.state != .expanded
                              && model.hoverBehavior == .highlight
                          ? IslandTheme.hoverTint : Color.clear,
                          style: FillStyle(eoFill: true))
            }
            // 黑线：线宽取两倍，里外各一半。落在里面那半压在纯黑岛体上看不出来，
            // 露在外面的正好是要的 0.5pt。
            .overlay {
                outline.stroke(IslandTheme.edgeLine,
                               lineWidth: IslandTheme.edgeLineWidth * 2)
                    .opacity(showsEdges ? 1 : 0)
            }
            // 亮线：同样取两倍线宽，再按轮廓裁掉外面那一半，只剩内侧 1pt。
            // 它盖住黑线内侧那一半 —— 从里往外于是正好是 1pt 白、0.5pt 黑。
            // **顺序不能反**：先描亮线的话，黑线会把它压掉一半，剩 0.5pt。
            .overlay {
                outline.stroke(IslandTheme.edgeHighlight,
                               lineWidth: IslandTheme.edgeHighlightWidth * 2)
                    .clipShape(shape)
                    .opacity(showsEdges ? 1 : 0)
            }
            // 收进 idle 时阴影要**淡出**，不能整层拿掉 —— `.shadow` 是不是挂着
            // 属于视图结构，结构一变 SwiftUI 直接换一棵树、当帧闪一下。
            // 颜色插到透明是同一棵树上的动画，跟着 `morph` 一起收。
            .shadow(color: showsEdges ? IslandTheme.edgeShadow : .clear,
                    radius: IslandTheme.edgeShadowRadius,
                    y: IslandTheme.edgeShadowOffsetY)
    }

    private var content: some View {
        VStack(spacing: 0) {
            StatusBand(model: model,
                       totalWidth: size.width,
                       notchGap: model.geometry.notchWidth ?? 0,
                       height: model.geometry.menuBarHeight)

            if model.state == .notice || model.state == .expanded {
                TabStrip(model: model, onNewTask: model.beginNewTask)
                    .transition(.opacity)
            }

            if model.state == .expanded {
                if model.showsNewTaskForm {
                    NewTaskForm(projects: model.projects,
                                error: model.launchError,
                                bottomInset: PanelCard.bottomInset,
                                onSubmit: { model.startTask(in: $0, instruction: $1) },
                                onCancel: model.cancelNewTask)
                        .transition(.opacity)
                } else {
                    // **展开态底下就这一层，内容区自己铺满。**
                    //
                    // 这里先后拆掉过两条：
                    //
                    // 1. `UsageBar`（ctx / 5h / 周 / 模式芯片 / 停止键）。终端里
                    //    Claude Code 自己那条 statusline 就写着上下文和模式，岛再抄
                    //    一遍是同一份信息占两行；中断也已经归 Esc（直接进 PTY）。
                    // 2. `InputBar`（2026-08-04）。它只在**没有活进程**的时候画
                    //    ——会话活着时键盘直接归终端，再摞一个框就是两个光标抢一份
                    //    键入。可「没有活进程」恰恰意味着它按回车写进去的 PTY 是死的：
                    //    `submitToSelected` 走 `runtime.write` 落到一个已经退出的
                    //    会话上，什么都不会发生。用户 08-04 的原话是「没有任何作用的，
                    //    整合成一个内框」。要接着聊就按「继续上次会话」（`--resume`），
                    //    那才是真的把进程带回来。
                    //
                    // 两条拆掉的高度都没有从岛的总高里减掉（见
                    // `IslandConstants.retiredInputBarHeight`），内容区吃下去了。
                    ContentArea(model: model, tab: model.selectedTab,
                                bottomInset: PanelCard.bottomInset)
                        .transition(.opacity)
                }
            }
        }
        // 内凹圆弧占掉的两条边不放内容。
        .padding(.horizontal, radii.inverted)
        .clipped()
    }
}

#Preview("四态") {
    // 四个模型各停在一个状态，纵向排开肉眼比对 states-v2.html。
    VStack(spacing: 24) {
        ForEach(IslandState.allCases, id: \.self) { state in
            IslandShell(model: .previewModel(state: state))
                .frame(width: 700, height: state == .expanded ? 430 : 90)
                .background(Color(white: 0.12))
        }
    }
    .padding()
    .frame(width: 740)
}

extension IslandModel {
    /// 预览用：造出停在指定状态的模型。
    static func previewModel(state: IslandState) -> IslandModel {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.previewState(state)
        return model
    }
}
