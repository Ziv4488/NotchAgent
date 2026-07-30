//
//  IslandShell.swift
//  NotchAgent
//
//  岛的渲染入口。四态共用一套结构，靠 spring 同时插值宽、高、圆角。
//

import SwiftUI

struct IslandShell: View {
    @Bindable var model: IslandModel

    private var size: CGSize { model.size }
    private var radii: IslandCornerRadii { model.cornerRadii }
    /// 内凹圆弧画在主体两侧之外，所以整块画布比主体宽 2×inverted。
    private var canvasWidth: CGFloat { size.width + radii.inverted * 2 }

    var body: some View {
        island
            // 画布固定为最大态尺寸，岛在里面变形 —— 每帧改 NSWindow 的 frame 会抖。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(IslandTheme.morph, value: model.state)
            .animation(IslandTheme.morph, value: model.tabs)
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
                                onSubmit: model.startTask(in:instruction:),
                                onCancel: model.cancelNewTask)
                        .transition(.opacity)
                } else {
                    ContentArea(tab: model.selectedTab)
                        .transition(.opacity)
                    // app tab 的内容区、用量条和输入框整体不绘制，
                    // 真实窗口贴在下面，额度也不归我们管（spec 3.2）。
                    if model.selectedTab?.kind != .app {
                        UsageBar(usage: model.selectedTab?.usage ?? SessionUsage(),
                                 onCycleMode: model.cycleMode)
                            .transition(.opacity)
                        InputBar(isRunning: model.selectedTab?.status == .running,
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
