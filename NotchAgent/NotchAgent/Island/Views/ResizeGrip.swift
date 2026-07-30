//
//  ResizeGrip.swift
//  NotchAgent
//
//  展开态底边的拖拽手柄。中间段改高度，两个下角同时改宽高。
//

import SwiftUI
import AppKit

struct ResizeGrip: View {
    let model: IslandModel

    /// 拖拽起点的尺寸。用起点 + 累计位移算，而不是逐帧累加 —— 后者会漂。
    @State private var origin: CGSize?

    var body: some View {
        HStack(spacing: 0) {
            // 岛是相对屏幕中线对称的，所以左边缘往左拖 1pt，总宽要长 2pt。
            corner(widthGain: -2).cursor(.resizeLeftRight)
            handle(widthGain: 0)
                .frame(maxWidth: .infinity)
                .overlay { grip }
                .cursor(.resizeUpDown)
            corner(widthGain: 2).cursor(.resizeLeftRight)
        }
        .frame(height: Layout.height)
        // 底部两个圆角以内才是岛，手柄不能压到弧线外面去。
        .padding(.horizontal, Layout.cornerInset)
    }

    /// 让用户看得见这里能拖。不画就等于没有这个功能。
    private var grip: some View {
        Capsule()
            .fill(Color.white.opacity(0.16))
            .frame(width: 28, height: 3)
    }

    private func corner(widthGain: CGFloat) -> some View {
        handle(widthGain: widthGain).frame(width: Layout.cornerWidth)
    }

    private func handle(widthGain: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = origin ?? CGSize(width: model.expandedWidth,
                                                    height: model.expandedContentHeight)
                        if origin == nil { origin = base }
                        model.resizeExpanded(
                            width: base.width + value.translation.width * widthGain,
                            contentHeight: base.height + value.translation.height)
                    }
                    .onEnded { _ in origin = nil }
            )
    }

    private enum Layout {
        static let height: CGFloat = 12
        static let cornerWidth: CGFloat = 28
        static let cornerInset: CGFloat = 6
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorArea(cursor: cursor))
    }
}

private struct CursorArea: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            // push / pop 必须严格配对，多 pop 一次光标就会卡在 resize 形状上出不来。
            if inside, !pushed {
                cursor.push()
                pushed = true
            } else if !inside, pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}
