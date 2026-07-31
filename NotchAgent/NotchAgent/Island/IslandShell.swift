//
//  IslandShell.swift
//  NotchAgent
//
//  岛的渲染入口。四态共用一套结构，靠 spring 同时插值宽、高、圆角。
//

import SwiftUI

/// 选项浮层在画布里的位置。窗口层拿它放行命中测试。
private struct MenuFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct IslandShell: View {
    @Bindable var model: IslandModel

    /// 报告浮层位置用的坐标系。原点就是画布左上角，和 `NotchHostingView` 的一致。
    fileprivate static let canvas = "island-canvas"

    private var size: CGSize { model.size }
    private var radii: IslandCornerRadii { model.cornerRadii }
    /// 内凹圆弧画在主体两侧之外，所以整块画布比主体宽 2×inverted。
    private var canvasWidth: CGFloat { size.width + radii.inverted * 2 }

    var body: some View {
        VStack(spacing: 6) {
            island
            // 终端在问话时，选项直接挂在岛下面点（spec 3.1）。
            // 窗口本来就按最大态尺寸开着（见 IslandMetrics.containerFrame），
            // 收起态下面这一大片是空的，正好放它。
            if let menu = model.pendingMenu, let id = model.selectedTab?.id {
                MenuPanel(menu: menu) { model.choose($0, in: id) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    // 命中测试被收在岛的轮廓里（见 NotchHostingView），
                    // 这块浮层在轮廓之外 —— 不把它的位置报上去，点了没反应。
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: MenuFrameKey.self,
                                                   value: proxy.frame(in: .named(Self.canvas)))
                        }
                    }
            }
        }
        .coordinateSpace(name: Self.canvas)
        .onPreferenceChange(MenuFrameKey.self) { frame in
            MainActor.assumeIsolated { model.menuFrame = frame }
        }
        // 画布固定为最大态尺寸，岛在里面变形 —— 每帧改 NSWindow 的 frame 会抖。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(IslandTheme.morph, value: model.state)
        .animation(IslandTheme.morph, value: model.tabs)
        .animation(IslandTheme.morph, value: model.pendingMenu)
    }

    private var island: some View {
        content
            .frame(width: canvasWidth, height: size.height, alignment: .top)
            .background {
                NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
                    .fill(.black)
                    .overlay {
                        // 悬停只做轻微提亮，不展开、不预览（spec 3.1）。
                        NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
                            .fill(model.isHovering && model.state != .expanded
                                  ? IslandTheme.hoverTint : Color.clear)
                    }
                    // 这里先后去掉过两样东西：0.5pt 白色描边，和一圈投影。
                    // 岛是纯黑的，描边读起来是灰框不是高光；投影落在透明画布上是一层
                    // 洗不掉的黑雾，展开态四周尤其明显。岛靠形状立住，不靠这两样。
            }
            // 只有轮廓内才吃鼠标事件，画布其余部分让点击穿透到下面的 app。
            .contentShape(NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted))
            .onHover { model.isHovering = $0 }
            .onTapGesture {
                if model.state != .expanded { model.send(.click) }
            }
            .overlay(alignment: .top) {
                if model.state == .expanded {
                    ResizeHandles(model: model,
                                  islandSize: size,
                                  topInset: model.geometry.menuBarHeight)
                }
            }
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
                                onSubmit: { model.startTask(in: $0, instruction: $1) },
                                onCancel: model.cancelNewTask)
                        .transition(.opacity)
                } else {
                    ContentArea(model: model, tab: model.selectedTab)
                        .transition(.opacity)
                    // app tab 的内容区和输入框整体不绘制，真实窗口贴在下面（spec 3.2）。
                    //
                    // 这里原本还有一条 UsageBar（ctx / 5h / 周 / 模式芯片 / 停止键）。
                    // 拆掉了：CLI 会话的终端里 Claude Code 自己那条 statusline 就写着
                    // 上下文和模式，岛再抄一遍是同一份信息占两行；中断也已经归 Esc
                    // ——它现在直接进 PTY，比按一个我们画的按钮更接近真终端。
                    //
                    // 会话活着的时候键盘直接归终端（见 TerminalPane），
                    // 再摞一个输入框就是两个光标抢一份键入，只在没有活进程时才画它。
                    if model.selectedTab?.kind != .app, !model.selectedTabHasLiveTerminal {
                        InputBar(isRunning: false,
                                 onSubmit: model.submitToSelected,
                                 onStop: model.interruptSelectedTask)
                            .transition(.opacity)
                    }
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
