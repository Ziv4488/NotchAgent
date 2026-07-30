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
                    .overlay {
                        // 沿边缘微微浮起：0.5pt 高光。
                        NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(model.state == .idle ? 0.25 : 0.55),
                            radius: model.state == .idle ? 4 : 14,
                            y: model.state == .idle ? 2 : 10)
            }
            // 只有轮廓内才吃鼠标事件，画布其余部分让点击穿透到下面的 app。
            .contentShape(NotchShape(bottomRadius: radii.bottom, invertedRadius: radii.inverted))
            .onHover { model.isHovering = $0 }
            .onTapGesture {
                if model.state != .expanded { model.send(.click) }
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            StatusBand(model: model,
                       notchGap: model.geometry.notchWidth ?? 0,
                       height: model.geometry.menuBarHeight)

            if model.state == .notice || model.state == .expanded {
                TabStrip(model: model)
                    .transition(.opacity)
            }

            if model.state == .expanded {
                ContentArea(tab: model.selectedTab)
                    .transition(.opacity)
                if model.selectedTab?.kind != .app {
                    InputBar()
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
