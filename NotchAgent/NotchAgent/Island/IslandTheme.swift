//
//  IslandTheme.swift
//  NotchAgent
//
//  视觉常量。取自定稿的 states-v2.html。
//

import SwiftUI

enum IslandTheme {
    // 文字
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let bright = Color.white.opacity(0.95)

    // 状态点
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30d158
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.04)   // #ff9f0a
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.00)    // #0a84ff —— 在等你回话
    static let stop = Color(red: 0.90, green: 0.27, blue: 0.23)    // #e6453a —— 中断

    // 用量条
    static let meterTrack = Color.white.opacity(0.10)
    static let meterFill = Color.white.opacity(0.42)

    // 容器
    static let tabActiveFill = Color.white.opacity(0.11)

    /// 内容区（终端、新建表单、会话结束卡）的底色。**#1E1E1E，不是纯黑。**
    ///
    /// 岛体本身必须是纯黑 —— 它紧挨着物理刘海，浅一点就露接缝（计划 4.3
    /// 「岛体保持纯黑不可配」说的就是这条）。但内容区是**长时间盯着读**的那一块，
    /// 纯黑底配亮字把对比度拉到顶，久了眼睛发涩；用户 2026-08-01 报的就是这个。
    ///
    /// 取值来自用户给的那张截图里占了 88 万像素的底色。
    /// 这里不能再写成半透明白叠在岛上 —— 那样算出来是 #0B0B0B，还是黑。
    ///
    /// 第 4 阶段的「终端配色与字体主题」会把它变成可配置项的**默认值**。
    static let panelFill = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let panelStroke = Color.white.opacity(0.07)

    // 终端。这三项是第 4 阶段「终端配色与字体主题」的默认值，
    // 放在这里是为了能被测到（对比度、和 panelFill 的关系），别散回视图里。
    static let terminalForeground = NSColor(white: 0.92, alpha: 1)
    static let terminalCaret = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    /// 终端字号。**12 不是拍脑袋**：用户给了一张「就要这么大」的截图，
    /// 量出来的等宽格宽 7.5pt、汉字墨高 11.5pt；岛上原来 11pt 是 7.1 / 10.0。
    /// 两个比值分别指向 11.6 和 12.6，取中。
    ///
    /// 代价是列数：默认 560pt 宽的岛从约 82 列掉到约 75 列。Claude Code 的
    /// diff 和表格在 60 列以下才散，75 还宽裕；但岛要是被拖到很窄，这里得一起考虑。
    static let terminalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// 输入框跟内容区**同一个表面色**。
    ///
    /// 它就贴在内容区下面。内容区提到 #1E1E1E 之后，输入框还留在半透明白
    /// 算出来的 #121212，看着像卡片下面破了个洞。区分这两块靠 `inputStroke`
    /// 那圈 0.5pt 描边，不靠明暗差。
    static let inputFill = panelFill
    static let inputStroke = Color.white.opacity(0.09)

    /// 悬停时整块岛的轻微提亮（spec 3.1：只做高亮，不展开）。
    static let hoverTint = Color.white.opacity(0.05)

    // 字号
    static let bandFont = Font.system(size: 11, weight: .medium)
    /// 同一个字体的 AppKit 形态。状态带的文案要**先量宽度再截断**
    /// （见 `StatusFeed.activity`），而 SwiftUI 的 `Font` 量不了。两者必须一致。
    static let bandNSFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let tabFont = Font.system(size: 11, weight: .medium)
    static let bodyFont = Font.system(size: 11, design: .monospaced)
    static let inputFont = Font.system(size: 12)
    static let meterFont = Font.system(size: 9.5, weight: .medium)

    /// 状态切换的动画。宽、高、圆角同时插值。
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.78)
}
