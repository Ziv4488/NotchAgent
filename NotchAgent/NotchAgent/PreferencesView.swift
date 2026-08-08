//
//  PreferencesView.swift
//  NotchAgent
//
//  偏好设置面板（plan 4.2）。终端主题 / 字号 / 字体 + 悬停行为。
//  引擎（ThemeStore / Preferences）不用重写。
//

import SwiftUI
import AppKit

struct PreferencesView: View {
    private let preferences = Preferences()

    @State private var hoverBehavior: HoverBehavior
    @State private var importAlert: ImportAlert?

    let onRestyleTerminals: () -> Void
    let onHoverBehaviorChanged: (HoverBehavior) -> Void

    init(onRestyleTerminals: @escaping () -> Void,
         onHoverBehaviorChanged: @escaping (HoverBehavior) -> Void) {
        let prefs = Preferences()
        self._hoverBehavior = State(initialValue: prefs.hoverBehavior)
        self.onRestyleTerminals = onRestyleTerminals
        self.onHoverBehaviorChanged = onHoverBehaviorChanged
    }

    var body: some View {
        Form {
            Section("通用") {
                Picker("悬停行为", selection: $hoverBehavior) {
                    Text("轻微高亮").tag(HoverBehavior.highlight)
                    Text("无反应").tag(HoverBehavior.none)
                }
            }

            Section("终端") {
                themePicker
                fontFamilyPicker
                fontSizePicker
                Button("导入配色文件…") { importThemeFile() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: hoverBehavior) { _, new in
            preferences.hoverBehavior = new
            onHoverBehaviorChanged(new)
        }
        .alert("没能读出这份配色",
               isPresented: Binding(
                   get: { importAlert != nil },
                   set: { if !$0 { importAlert = nil } }
               )) {
            Button("好") { importAlert = nil }
        } message: {
            if let alert = importAlert {
                Text(alert.message)
            }
        }
    }

    // MARK: - 终端主题

    private var themes: [TerminalTheme] {
        var list = TerminalTheme.builtins
        let current = ThemeStore.shared.theme
        if !list.contains(current) { list.append(current) }
        return list
    }

    private var themePicker: some View {
        Picker("主题", selection: Binding(
            get: { ThemeStore.shared.theme.name },
            set: { name in
                if let theme = themes.first(where: { $0.name == name }) {
                    ThemeStore.shared.select(theme)
                    onRestyleTerminals()
                }
            }
        )) {
            ForEach(themes, id: \.name) { theme in
                Text(theme.name).tag(theme.name)
            }
        }
    }

    private var fontFamilyPicker: some View {
        let families = ThemeStore.availableMonospacedFamilies()
        return Picker("字体", selection: Binding(
            get: { ThemeStore.shared.fontFamily ?? "" },
            set: { family in
                ThemeStore.shared.selectFontFamily(family.isEmpty ? nil : family)
                onRestyleTerminals()
            }
        )) {
            Text("系统等宽").tag("")
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
    }

    private var fontSizePicker: some View {
        let sizes = Array(stride(from: CGFloat(10), through: 18, by: 1))
        return Picker("字号", selection: Binding(
            get: { ThemeStore.shared.fontSize },
            set: { size in
                ThemeStore.shared.selectFontSize(size)
                onRestyleTerminals()
            }
        )) {
            ForEach(sizes, id: \.self) { size in
                Text("\(Int(size))").tag(size)
            }
        }
    }

    // MARK: - 导入配色

    private struct ImportAlert {
        let failure: TerminalThemeImport.Failure
        let fileName: String

        var message: String {
            switch failure {
            case .unreadable:
                "\(fileName) 打不开。"
            case .unknownFormat:
                "\(fileName) 既不是 iTerm 的 .itermcolors，也不像 Ghostty 的主题文件。"
            case .incomplete(let reason):
                "\(fileName) 里\(reason)。终端要完整的 16 色 ANSI 调色板才能上色。"
            }
        }
    }

    private func importThemeFile() {
        let panel = NSOpenPanel()
        panel.title = "选择配色文件"
        panel.message = "支持 iTerm 的 .itermcolors 与 Ghostty 的主题文件。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []

        NSApp.activate(ignoringOtherApps: true)
        let response = NotchWindow.steppingAside { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }

        switch ThemeStore.shared.importTheme(contentsOf: url) {
        case .success:
            onRestyleTerminals()
        case .failure(let failure):
            importAlert = ImportAlert(failure: failure, fileName: url.lastPathComponent)
        }
    }
}
