//
//  SpikeControlView.swift
//  第 0 阶段探针 B / C 的操作面板。抛弃型代码，第 0.6 步会删除。
//

import SwiftUI
import AppKit

struct SpikeControlView: View {
    @State private var panel: SpikePanel?
    @State private var allowsKey = false

    @State private var trusted = SpikeAX.isTrusted
    @State private var candidates: [SpikeAX.Candidate] = []
    @State private var selected: pid_t?
    @State private var report = ""
    @State private var probing = false

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

                Toggle("允许键盘焦点（canBecomeKey）", isOn: $allowsKey)
                    .onChange(of: allowsKey) { _, v in panel?.allowsKey = v }
                    .disabled(panel == nil)
            }

            Text("""
            按顺序测，每步的结果记下来：

            1. 打开面板，**不要**勾选上面的开关。面板应该浮在菜单栏之上。
            2. 点一下 Safari 或别的 app 并打字 —— 字应该进那个 app，面板不抢焦点。
            3. 勾选开关，再点面板里的终端，打字 —— 应该进终端。试 Ctrl-C、方向键、Esc。
            4. **切中文输入法打一段中文** —— 这是最可能出问题的一步。注意候选框位置对不对、\
            字能不能上屏。
            5. 取消勾选 —— 焦点应该交还给上一个 app。
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                Button("刷新状态") {
                    trusted = SpikeAX.isTrusted
                    candidates = SpikeAX.candidates()
                }
            }

            if !trusted {
                Text("授权后需要**重新运行 app** 才会生效。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("先把要测的 app 打开（ChatGPT / Claude / Cursor / 终端），再回来刷新列表。")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(candidates, selection: $selected) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Text(c.bundleID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .tag(c.pid)
            }
            .frame(height: 160)

            HStack {
                Button(probing ? "探测中…" : "探测选中的 app") {
                    guard let pid = selected,
                          let c = candidates.first(where: { $0.pid == pid }) else { return }
                    probing = true
                    SpikeAX.probe(pid: c.pid, name: "\(c.name)  [\(c.bundleID)]") { text in
                        report = report.isEmpty ? text : report + "\n\n" + text
                        probing = false
                    }
                }
                .disabled(selected == nil || probing || !trusted)

                Button("清空报告") { report = "" }
                    .disabled(report.isEmpty)

                Button("复制报告") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(report.isEmpty)
            }

            Text("探测会临时移动/缩放目标窗口，结束后自动恢复原位。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !report.isEmpty {
                ScrollView {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
