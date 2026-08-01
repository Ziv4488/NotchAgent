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
    /// 新建流程里这张表单**就是岛最底下那一层**，下面要留出岛体的黑边。
    /// 不给的话（预览、单测）按普通卡片画。见 `PanelCard.bottomInset`。
    var bottomInset: CGFloat = 0
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
            // **钉在列表外面。** 它原来是滚动列表里的最后一行，项目一多就滚出了
            // 视野；空列表时那一支干脆不绘制，而空态文案还写着「用下面的选择其他
            // 目录…」——指着一个不存在的按钮。用户报的「只能 resume、开不了新目录」
            // 就是这么来的：`~/.claude/projects` 里没有的目录，界面上找不到入口。
            chooseOther
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
        .background { PanelCard() }
        .padding(.horizontal, PanelCard.inset)
        .padding(.bottom, bottomInset)
        .onAppear {
            selected = projects.first
            // 抢两次：NSApp.activate() 是异步的，onAppear 时窗口可能还没成为 key，
            // app 激活后 AppKit 会把 first responder 恢复成它记着的上一个，把这里顶掉。
            instructionFocused = true
            Task { @MainActor in instructionFocused = true }
        }
    }

    private var empty: some View {
        Text("~/.claude/projects 里还没有项目。用下面那行挑一个目录。")
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

    /// 用「选择其他目录…」挑出来、但不在列表里的那个。挑完了得看得见，
    /// 否则界面上没有任何地方显示你选了什么，只有指令框的占位符悄悄变了。
    private var chosenOutsideList: ProjectDirectory? {
        guard let selected, !projects.contains(selected) else { return nil }
        return selected
    }

    private var chooseOther: some View {
        Button {
            chooseDirectory()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: chosenOutsideList == nil ? "ellipsis.circle" : "folder.fill")
                    .font(.system(size: 10))
                Text(chosenOutsideList?.name ?? "选择其他目录…")
                    .font(IslandTheme.tabFont)
                if let chosen = chosenOutsideList {
                    Text(chosen.displayPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(IslandTheme.faint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(chosenOutsideList == nil ? IslandTheme.dim : IslandTheme.bright)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chosenOutsideList == nil ? Color.clear : IslandTheme.tabActiveFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
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

        // LSUIElement 的 app 不是前台时，模态框可能开在别人后面。
        NSApp.activate()

        // 选择框期间岛让到普通层级，否则会被岛盖掉中间一大块（见 steppingAside）。
        let result = NotchWindow.steppingAside { panel.runModal() }

        guard result == .OK, let url = panel.url else { return }
        selected = ProjectDirectory(path: url.path, lastUsed: .now, hasSessions: false)
        instructionFocused = true
    }
}
