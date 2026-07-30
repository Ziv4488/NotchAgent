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
    static let panelFill = Color.white.opacity(0.045)
    static let panelStroke = Color.white.opacity(0.07)
    static let inputFill = Color.white.opacity(0.07)
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
