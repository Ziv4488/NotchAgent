//
//  UsageProbe.swift
//  NotchAgent
//
//  用量条那三个数字的真实来源。
//

import Foundation

/// 读出上下文占用与账号限额。
///
/// **这三个数字 hook payload 里一个都没有**，得各自去找源头。口径照抄 Claude Code
/// 自己那条 statusline —— 岛上显示的百分比必须和用户在终端里看到的是同一个数，
/// 差一点点比不显示更糟：他会开始怀疑到底该信哪个。
///
/// 拿不到就是拿不到，一律返回 nil 让界面画一条短横线。**绝不用 0 顶替** ——
/// 「额度用了 0%」和「不知道用了多少」是两件完全不同的事。
enum UsageProbe {

    // MARK: - 上下文

    /// Claude Code 触发自动压缩的阈值，也是它算「上下文 N%」时的分母。
    /// 不是模型的真实上下文窗口（Opus 5 报的是 1,000,000）——
    /// 用真实窗口算出来的数会和用户在终端里看到的对不上。
    static let contextBudget = 200_000.0

    /// 从会话记录里读出这一轮吃掉了多少上下文。
    ///
    /// 只读文件尾部：transcript 会长到几十 MB，整篇读进来会卡住主线程。
    static func contextRatio(transcriptPath: String, tailBytes: Int = 512 * 1024) -> Double? {
        guard let tokens = lastAssistantInputTokens(transcriptPath: transcriptPath, tailBytes: tailBytes) else {
            return nil
        }
        return min(Double(tokens) / contextBudget, 1)
    }

    static func lastAssistantInputTokens(transcriptPath: String, tailBytes: Int) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // 从后往前找第一条带 usage 的 assistant 消息 —— 那就是最新的上下文占用。
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            // 三项都要算进去：缓存命中的部分照样占着上下文窗口。
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .compactMap { usage[$0] as? Int }
                .reduce(0, +)
            return tokens > 0 ? tokens : nil
        }
        return nil
    }

    // MARK: - 账号限额

    struct Limits: Equatable {
        /// 0...1。
        var fiveHour: Double
        var weekly: Double
        /// 这份数据是什么时候取的。
        var fetchedAt: Date
    }

    /// 读 Claude Code 自己维护的限额缓存。
    ///
    /// **有意不去调 OAuth 接口。** 用户的 statusline 脚本是从钥匙串里掏 token
    /// 直接打 `api.anthropic.com/api/oauth/usage` 拿实时数据的；岛不该那么做 ——
    /// 那意味着读用户的凭据、替他发网络请求。读 Claude Code 已经落盘的缓存，
    /// 不碰钥匙串、不联网，代价是数据可能旧一点（见 `staleAfter`）。
    static func limits(configPath: String? = nil) -> Limits? {
        let path = configPath ?? NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parseLimits(data)
    }

    static func parseLimits(_ data: Data) -> Limits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else { return nil }

        func ratio(_ key: String) -> Double? {
            guard let bucket = utilization[key] as? [String: Any],
                  let value = bucket["utilization"] as? Double else { return nil }
            return min(max(value / 100, 0), 1)
        }
        guard let fiveHour = ratio("five_hour"), let weekly = ratio("seven_day") else { return nil }

        let fetchedAt = (cached["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        } ?? .distantPast
        return Limits(fiveHour: fiveHour, weekly: weekly, fetchedAt: fetchedAt)
    }

    /// 超过这个时间就当不知道。
    ///
    /// Claude Code 只在它自己需要的时候刷新那份缓存（比如你开 `/usage`），
    /// 隔天再读到的数字可能完全不作数。**宁可显示一条横线，也不要显示一个过期的百分比** ——
    /// 用户会照着它决定还能不能接着干活。
    static let staleAfter: TimeInterval = 15 * 60

    static func fresh(_ limits: Limits?, now: Date = .now) -> Limits? {
        guard let limits, now.timeIntervalSince(limits.fetchedAt) < staleAfter else { return nil }
        return limits
    }
}
