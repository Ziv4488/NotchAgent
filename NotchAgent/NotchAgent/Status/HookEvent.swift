//
//  HookEvent.swift
//  NotchAgent
//
//  Claude Code hook payload 的解码（spec 5.2）。
//  字段以 scripts/spike-hooks.sh + spike-notification.py 抓到的真实 payload 为准，
//  样本存在 NotchAgentTests/Fixtures/hooks/。
//

import Foundation

/// 一条 hook 事件。
///
/// **解码只认自己要的字段，其余一律无视。** Claude Code 会往 payload 里加东西
/// （实测 2.1.220 就比文档多出 `effort`、`prompt_id`、`background_tasks`、`session_crons`），
/// 用严格 `Codable` 去接必然某次升级就整个通道哑掉。这里手写解析、缺字段就降级。
struct HookEvent: Equatable {
    enum Kind: String, Equatable {
        case sessionStart = "SessionStart"
        /// 用户按下回车、一个回合真的开始了。计时从这里起算。
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case notification = "Notification"
        case stop = "Stop"
    }

    var kind: Kind
    var sessionID: String
    var cwd: String? = nil
    /// 该会话的 JSONL 记录路径。上下文占用是从这里读出来的（见 `UsageProbe`）。
    var transcriptPath: String? = nil
    var toolName: String? = nil
    /// `tool_input` 里最能说明「在动什么」的那个值：文件路径、命令、URL。
    var toolTarget: String? = nil
    /// `Notification` 的提示文本，实测是 `"Claude needs your permission"`。
    var message: String? = nil
    /// `Notification` 的种类，实测有 `permission_prompt`。
    ///
    /// 文档里没有这个字段，是探针抓出来的。有它就能把「在等你批权限」和
    /// 「闲着太久提醒你一声」分开 —— 前者该让岛快闪催人，后者不该。
    var notificationType: String? = nil
    /// payload 里带的权限模式（`default` / `acceptEdits` / `plan` / `bypassPermissions`）。
    ///
    /// 计划里原本打算让用户在岛上点模式芯片、再想办法喂给 CLI；
    /// 探针发现 payload **本来就带着它**，于是方向反过来：以 CLI 为准，岛只负责显示。
    var permissionMode: String? = nil

    static func decode(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> HookEvent? {
        guard let rawKind = object["hook_event_name"] as? String,
              let kind = Kind(rawValue: rawKind),
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty else {
            return nil
        }
        let input = object["tool_input"] as? [String: Any]
        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            cwd: object["cwd"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            toolName: object["tool_name"] as? String,
            toolTarget: input.flatMap(target(inToolInput:)),
            message: object["message"] as? String,
            notificationType: object["notification_type"] as? String,
            permissionMode: object["permission_mode"] as? String)
    }

    /// 不同工具把「对象」放在不同的键下，按最有信息量的顺序挑第一个命中的。
    private static func target(inToolInput input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "command", "pattern", "url", "path", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

/// 事件里的 `permission_mode` → 岛上显示的档位。
extension SessionUsage.Mode {
    /// Claude Code 内部的模式标识。岛显示的是 `label`，两者一一对应但**不是同一个字符串** ——
    /// 内部标识是 `default`/`bypassPermissions`，用户在 ⇧Tab 选单里看到的是 `Manual`/`Auto`。
    var wireName: String {
        switch self {
        case .manual: "default"
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .auto: "bypassPermissions"
        }
    }

    init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }
}
