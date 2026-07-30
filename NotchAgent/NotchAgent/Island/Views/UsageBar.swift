//
//  UsageBar.swift
//  NotchAgent
//
//  展开态输入框上方的一行：额度、模式、子代理。
//  等价于终端里 Claude Code 自己那条 statusline，但常驻可见。
//

import SwiftUI

struct UsageBar: View {
    let usage: SessionUsage
    /// 会话正在跑。停止键只在这时候出现。
    var isRunning: Bool = false
    var onCycleMode: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        HStack(spacing: 9) {
            meter("ctx", usage.contextUsed)
            meter("5h", usage.fiveHourUsed)
            meter("周", usage.weeklyUsed)

            Spacer(minLength: 6)

            if usage.subagents > 0 { subagents }
            modeChip
            // 停止键原本在输入框右端。CLI 会话跑起来后键盘归终端、输入框不再绘制，
            // 它就搬到这里 —— 「手边随时有个中断的办法」这条不能跟着输入框一起没掉。
            if isRunning { stopButton }
        }
        .font(IslandTheme.meterFont)
        .frame(height: 22)
        .padding(.horizontal, 9)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background { Circle().fill(IslandTheme.stop) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("停止（等同在终端里按 Esc）")
    }

    // MARK: - 额度

    /// `value` 为 nil 表示**不知道**，画一条空槽 + 一个短横线。
    ///
    /// 拿不到数据时显示 0% 是最坏的选择：用户会照着这个数决定还能不能接着干活，
    /// 而「额度还没动」和「我不知道额度用了多少」是完全相反的两条结论。
    private func meter(_ label: String, _ value: Double?) -> some View {
        let ratio = value.map { min(max($0, 0), 1) }
        return HStack(spacing: 4) {
            Text(label).foregroundStyle(IslandTheme.faint)
            Capsule()
                .fill(IslandTheme.meterTrack)
                .frame(width: Layout.meterWidth, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        // 过了八成就转成琥珀色 —— 快用完是个需要提前知道的事。
                        .fill((ratio ?? 0) >= 0.8 ? IslandTheme.amber : IslandTheme.meterFill)
                        .frame(width: Layout.meterWidth * (ratio ?? 0), height: 3)
                }
            Text(ratio.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .foregroundStyle(IslandTheme.dim)
                .monospacedDigit()
        }
        .lineLimit(1)
    }

    // MARK: - 子代理

    private var subagents: some View {
        HStack(spacing: 3) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 8.5))
            Text("\(usage.subagents)").monospacedDigit()
        }
        .foregroundStyle(IslandTheme.dim)
    }

    // MARK: - 模式

    /// 点一下轮换，快捷键 ⇧Tab 是同一个动作 —— 键盘用户不该被迫去摸鼠标。
    private var modeChip: some View {
        Button(action: onCycleMode) {
            HStack(spacing: 4) {
                Text(usage.mode.label)
                    .foregroundStyle(usage.mode.isDefault ? IslandTheme.dim : IslandTheme.blue)
                Text("⇧⇥").foregroundStyle(IslandTheme.faint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(Color.white.opacity(usage.mode.isDefault ? 0.06 : 0.12))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private enum Layout {
        static let meterWidth: CGFloat = 26
    }
}

#Preview {
    VStack(spacing: 6) {
        UsageBar(usage: SessionUsage(contextUsed: 0.42, fiveHourUsed: 0.31,
                                     weeklyUsed: 0.12, mode: .manual, subagents: 2))
        UsageBar(usage: SessionUsage(contextUsed: 0.88, fiveHourUsed: 0.93,
                                     weeklyUsed: 0.64, mode: .plan, subagents: 0))
    }
    .frame(width: 560)
    .background(.black)
}
