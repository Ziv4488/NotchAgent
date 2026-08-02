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
    /// 触发这条事件的工具名（`Read` / `Edit` / `Bash` …）。
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

    // payload 里还有 `permission_mode` 和 `transcript_path`，**故意不解析**：
    // 前者曾经喂给岛上的模式芯片、后者喂给用量条，两样都在 2026-08-01/08-02
    // 删掉了。解析一个没人看的字段只会让人以为它还有用。要用的时候去翻 git，
    // 那里记着四个内部标识（`default`/`acceptEdits`/`plan`/`bypassPermissions`）
    // 和它们对应的显示名。

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
            toolName: object["tool_name"] as? String,
            toolTarget: input.flatMap(target(inToolInput:)),
            message: object["message"] as? String,
            notificationType: object["notification_type"] as? String)
    }

    /// 不同工具把「对象」放在不同的键下，按最有信息量的顺序挑第一个命中的。
    private static func target(inToolInput input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "command", "pattern", "url", "path", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
