//
//  IslandState.swift
//  NotchAgent
//
//  岛的四态状态机。纯函数，不碰 UI、不碰会话存储。
//

import Foundation

enum IslandState: String, CaseIterable, Sendable {
    /// 无任务在跑且无未读。只沿刘海边缘微微浮起。
    case idle
    /// 至少一个任务在跑。横向撑开显示状态。
    case running
    /// 有任务完成待查看。弹出 tab 条，常驻直到点开。
    case notice
    /// 用户点开。tab 条 + 内容区 + 输入框。
    case expanded
}

enum IslandEvent: Sendable {
    /// 新会话开始跑。
    case sessionStarted
    /// 会话有进展（工具调用、输出）。只刷新文案，不该打断当前形态。
    case sessionProgress
    /// 某个会话跑完了（收到 Stop）。
    case sessionStopped
    /// 用户点开了某个 tab，该 tab 的未读被清除。
    case tabOpened
    /// 用户点击岛本体。
    case click
    /// 用户收起岛（点关闭、点岛外、Esc）。
    case dismiss
    /// 所有未读被清空。
    case allRead
    /// 最后一个 tab 被关闭，已经没有会话了。
    case lastSessionEnded
}

/// 状态机需要的外部计数。
///
/// **约定**：`context` 反映的是事件*已经*作用于会话存储之后的计数。
/// 也就是说 `sessionStopped` 到达 `reduce` 时，`runningCount` 已经减过、
/// `unreadCount` 已经加过。这样 `reduce` 只需判断"现在该是什么形态"，
/// 不必自己推演计数，否则两边各算一遍必然会算歪。
struct IslandContext: Equatable, Sendable {
    /// 还在跑的会话数。
    var runningCount: Int = 0
    /// 未读（已完成但用户还没点开）的会话数。
    var unreadCount: Int = 0

    static let empty = IslandContext()
}

/// 没有用户交互压着时，岛该落在哪个形态。
///
/// 未读优先于运行中 —— 提醒用户去看比显示进度更重要。
private func settledState(_ context: IslandContext) -> IslandState {
    if context.unreadCount > 0 { return .notice }
    if context.runningCount > 0 { return .running }
    return .idle
}

/// 状态机主体。
func reduce(_ state: IslandState, _ event: IslandEvent, _ context: IslandContext) -> IslandState {
    switch event {
    case .click:
        // 任何形态点一下都进展开。
        return .expanded

    case .dismiss:
        // 收起后落回自然形态。仍有未读就留在 notice —— 通知常驻，直到真的点开。
        return settledState(context)

    case .tabOpened:
        // 点开 tab 必然是在看内容，展开。
        return .expanded

    case .allRead, .lastSessionEnded, .sessionProgress, .sessionStarted:
        // 展开态由用户掌控，后台事件不得打断。
        if state == .expanded { return .expanded }
        return settledState(context)

    case .sessionStopped:
        // 同上：展开时用户正在看，不打断。
        if state == .expanded { return .expanded }
        // 其余情况一律弹通知。即便 unreadCount 因为某种原因没跟上，
        // 完成事件本身就足以说明该提醒了。
        return .notice
    }
}
