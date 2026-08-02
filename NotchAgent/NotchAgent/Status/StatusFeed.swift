//
//  StatusFeed.swift
//  NotchAgent
//
//  hook 事件 → 收起态文案、tab 状态、模式（spec 5.2）。
//

import AppKit
import Foundation

/// 一条 hook 事件对一个会话的全部影响。
///
/// 故意做成**纯值**：`StatusFeed` 不碰 `IslandModel`，只回答「这条事件意味着什么」。
/// 于是全部映射逻辑都能用真实 payload 样本离线测，不用起进程、不用等界面。
struct SessionSignal: Equatable {
    /// 会话状态要改成什么。nil = 不改。
    var status: SessionStatus?
    /// 收起态状态带上显示的一行字，比如「读 session.ts」。nil = 不改。
    var activity: String?
    /// `SessionStart` 带来的 Claude Code 会话标识，用来做绑定。
    var claudeSessionID: String?
    /// 这条事件是否应该把岛推到 `notice`（完成未读 / 等你回话）。
    var demandsAttention: Bool = false
}

enum StatusFeed {
    static func signal(for event: HookEvent) -> SessionSignal {
        var signal = SessionSignal()
        switch event.kind {
        case .sessionStart:
            // **只认领这个会话，不动状态。**
            // `SessionStart` 的意思是「进程起来了、停在提示符前」，不是「开始干活」。
            // 早先在这里写 `.running`，结果一个什么都没干的会话状态点一直琥珀色
            // 慢呼吸、计时一路往上走 —— 而那个数字跟任何真实的干活时长都对不上。
            // 干活的起点是下面的 `userPromptSubmit`。
            signal.claudeSessionID = event.sessionID

        case .userPromptSubmit:
            // 回合真的开始了。计时从这一刻起算（见 IslandModel.apply 里的 startedAt）。
            signal.status = .running
            signal.activity = "思考中"

        case .preToolUse:
            signal.status = .running
            signal.activity = activity(tool: event.toolName, target: event.toolTarget)

        case .postToolUse:
            // 工具刚跑完，下一步是模型继续想。保留刚才那行字，只确保状态是「在跑」——
            // 每个工具结束都把文案清成「思考中」会让状态带一直在两句话之间跳。
            signal.status = .running

        case .notification:
            // 闲置提醒（没有 notification_type 或不是权限询问）不该让岛快闪催人：
            // 那种时候用户本来就没在等它，催一下反而是打扰。
            if event.notificationType == "permission_prompt" || event.notificationType == nil {
                signal.status = .waiting
                signal.activity = "等你回话"
                signal.demandsAttention = true
            }

        case .stop:
            signal.status = .idle
            signal.activity = "完成"
            signal.demandsAttention = true
        }
        return signal
    }

    /// 「读 session.ts」「改 session.ts」「跑 npm test」。
    ///
    /// **按真实字体量着截，不按字符数。** 早先按「10 个字符」截，实机截图里出现了
    /// 「读 manual-tests....」—— 我们截一次、SwiftUI 尾部又截一次，四个点。
    /// 字符数和像素宽度不是一回事（一个汉字 11pt，一个小写字母 5.4pt），
    /// 唯一可靠的办法是量出来再截。
    static func activity(tool: String?, target: String?,
                         maxWidth: CGFloat = bandTextWidth,
                         measure: (String) -> CGFloat = defaultMeasure) -> String {
        guard let tool else { return "工作中" }
        let verb = verb(for: tool)
        guard let target, !target.isEmpty else { return verb }

        var candidate = shorten(target)
        // 一个字一个字往回收，直到量得下。**动词不动** ——
        // 「读」比「文件名的最后三个字母」有用得多。
        while !candidate.isEmpty, measure("\(verb) \(candidate)") > maxWidth {
            let trimmed = String(candidate.dropLast(candidate.hasSuffix("…") ? 2 : 1))
            candidate = trimmed.isEmpty ? "" : trimmed + "…"
        }
        return candidate.isEmpty ? verb : "\(verb) \(candidate)"
    }

    /// 状态带左半边真正能写字的宽度。
    ///
    /// = `runningSideBleed`(88) − 内边距(10) − 状态点(5) − 点与字的间距(5)。
    /// 有一条测试盯着它和 `IslandConstants` 对得上，那边改了这里会红。
    static let bandTextWidth: CGFloat = 68

    static func defaultMeasure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: IslandTheme.bandNSFont]).width
    }

    /// 未知工具名要降级成通用动词，**不能崩也不能显示成空白** ——
    /// Claude Code 每次升级都可能加新工具，那时候岛不该跟着哑掉。
    static func verb(for tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead": "读"
        case "Edit", "Write", "NotebookEdit", "MultiEdit": "改"
        case "Bash", "BashOutput", "KillShell": "跑"
        case "Grep", "Glob": "找"
        case "WebFetch", "WebSearch": "查"
        case "Task", "Agent": "子代理"
        case "TodoWrite": "记"
        default: tool.hasPrefix("mcp__") ? "调用" : "工作中"
        }
    }

    /// 路径取文件名；命令取前两个词。都再截一次长度。
    ///
    /// 上限是 10 而不是「看着差不多就行」：状态带左半边只有 88pt，
    /// 扣掉 10pt 内边距、5pt 状态点、5pt 间距后剩 68pt，动词和空格又要去掉约 17pt。
    /// 截得不够狠的后果是 SwiftUI 会**再**尾部截断一次，屏幕上出现
    /// 「读 manual-tests....」这种四个点的怪东西 —— 实机上就是这么发现的。
    static func shorten(_ target: String, limit: Int = 10) -> String {
        var text = target
        if text.hasPrefix("/") || text.contains("/") {
            text = (text as NSString).lastPathComponent
        }
        let words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if words.count > 2 {
            text = words.prefix(2).joined(separator: " ")
        }
        guard text.count > limit else { return text }
        return text.prefix(limit - 1) + "…"
    }
}
