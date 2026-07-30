//
//  NewTaskForm.swift
//  NotchAgent
//
//  点 ＋ 之后的新建流程：选目录 → 下指令（spec 3.3）。
//

import SwiftUI
import AppKit

struct NewTaskForm: View {
    let projects: [ProjectDirectory]
    /// 上一次起会话失败的原因（找不到 `claude` 之类）。表单原地留着，把话说清楚。
    var error: String?
    var onSubmit: (ProjectDirectory, String) -> Void
    var onCancel: () -> Void

    @State private var selected: ProjectDirectory?
    @State private var instruction = ""
    @FocusState private var instructionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if projects.isEmpty {
                empty
            } else {
                list
            }
            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(error).lineLimit(2)
                }
                .font(IslandTheme.bodyFont)
                .foregroundStyle(IslandTheme.stop)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(IslandTheme.panelStroke)
            instructionField
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(IslandTheme.panelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 7)
        .onAppear {
            selected = projects.first
            // 抢两次：NSApp.activate() 是异步的，onAppear 时窗口可能还没成为 key，
            // app 激活后 AppKit 会把 first responder 恢复成它记着的上一个，把这里顶掉。
            instructionFocused = true
            Task { @MainActor in instructionFocused = true }
        }
    }

    private var empty: some View {
        Text("~/.claude/projects 里还没有项目。用下面的「选择其他目录…」挑一个。")
            .font(IslandTheme.bodyFont)
            .foregroundStyle(IslandTheme.faint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(projects) { project in
                    row(project)
                }
                chooseOther
            }
            .padding(4)
        }
    }

    private func row(_ project: ProjectDirectory) -> some View {
        Button {
            selected = project
            instructionFocused = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandTheme.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(IslandTheme.bright)
                    Text(project.displayPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(IslandTheme.faint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                if project.hasSessions {
                    Text("可继续")
                        .font(.system(size: 9))
                        .foregroundStyle(IslandTheme.faint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected == project ? IslandTheme.tabActiveFill : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chooseOther: some View {
        Button {
            chooseDirectory()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 10))
                Text("选择其他目录…")
                    .font(IslandTheme.tabFont)
                Spacer(minLength: 0)
            }
            .foregroundStyle(IslandTheme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var instructionField: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandTheme.faint)
            TextField(selected == nil ? "先选一个目录" : "给 \(selected!.name) 下达指令…",
                      text: $instruction)
                .textFieldStyle(.plain)
                .font(IslandTheme.inputFont)
                .foregroundStyle(IslandTheme.bright)
                .focused($instructionFocused)
                .disabled(selected == nil)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.16))
                    }
            }
            .buttonStyle(.plain)
            .disabled(selected == nil || instruction.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submit() {
        guard let selected, !instruction.isEmpty else { return }
        onSubmit(selected, instruction)
        instruction = ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = ProjectDirectory(path: url.path, lastUsed: .now, hasSessions: false)
        instructionFocused = true
    }
}
