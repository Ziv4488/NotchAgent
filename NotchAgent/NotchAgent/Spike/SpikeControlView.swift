//
//  SpikeControlView.swift
//  第 0 阶段探针 B / C 的操作面板。抛弃型代码，第 0.6 步会删除。
//

import SwiftUI
import AppKit

struct SpikeControlView: View {
    @State private var panel: SpikePanel?
    @State private var allowsKey = false
    @State private var diagnostics = ""

    @State private var trusted = SpikeAX.isTrusted
    @State private var candidates: [SpikeAX.Candidate] = []
    @State private var report = ""
    @State private var probingPID: pid_t?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                probeB
                Divider()
                probeC
            }
            .padding(20)
        }
        .onAppear { candidates = SpikeAX.candidates() }
    }

    // MARK: - 探针 B

    private var probeB: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("探针 B · 非激活面板里的终端能否收键")
                .font(.headline)

            HStack {
                Button(panel == nil ? "打开终端面板" : "面板已打开") {
                    let p = SpikePanel()
                    p.orderFront(nil)
                    p.startShell()
                    panel = p
                }
                .disabled(panel != nil)

                Toggle("展开（激活自己 + 拿焦点）", isOn: $allowsKey)
                    .onChange(of: allowsKey) { _, v in panel?.allowsKey = v }
                    .disabled(panel == nil)

                Button("读诊断") { diagnostics = panel?.diagnostics ?? "面板未打开" }
                    .disabled(panel == nil)
            }

            HStack {
                Button("采样窗口层级 10 秒") { SpikeWindowLevels.sample() }
                Text("点完立刻切到面板用输入法打字，让候选框一直显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("""
            这一版改了两处：展开时**主动激活本 app**（macOS 只把键给前台 app，\
            光靠非激活面板收不到键），并显式把终端设成 first responder。

            1. 打开面板，**不勾**开关。点 Safari 之类打字 —— 字应该进那个 app，面板不抢焦点。
            2. 勾上开关 —— 面板应该直接就能打字，不需要再点它。试 Ctrl-C、方向键、Esc。
            3. **切中文输入法打一段中文** —— 重点看候选框位置、能否上屏。
            4. 取消勾选 —— 焦点应该回到第 1 步那个 app。
            5. 任何一步不对，点「读诊断」把输出贴给我。
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !diagnostics.isEmpty {
                Text(diagnostics)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 探针 C

    private var probeC: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("探针 C · 第三方 app 吃不吃 AX 定位")
                .font(.headline)

            HStack(spacing: 10) {
                Circle()
                    .fill(trusted ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(trusted ? "已获得辅助功能权限" : "尚未获得辅助功能权限")
                if !trusted {
                    Button("请求授权") { SpikeAX.requestTrust() }
                }
                Button("刷新列表") {
                    trusted = SpikeAX.isTrusted
                    candidates = SpikeAX.candidates()
                }
            }

            Text("每行右边直接点「探测」。探测会临时移动/缩放该窗口，结束后自动恢复原位。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(candidates) { c in
                    HStack {
                        Text(c.name)
                            .frame(width: 150, alignment: .leading)
                        Text(c.bundleID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(probingPID == c.pid ? "探测中…" : "探测") {
                            probingPID = c.pid
                            SpikeAX.probe(pid: c.pid, name: "\(c.name)  [\(c.bundleID)]") { text in
                                report = report.isEmpty ? text : report + "\n\n" + text
                                probingPID = nil
                            }
                        }
                        .disabled(!trusted || probingPID != nil)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    Divider()
                }
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("清空报告") { report = "" }
                    .disabled(report.isEmpty)
                Button("复制报告") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(report.isEmpty)
            }

            if !report.isEmpty {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
