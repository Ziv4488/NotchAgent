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
    /// 选中的 tab 那圈描边。
    ///
    /// 原来是**只在顶边**的一条 0.5pt 亮线 —— 那是圆角矩形的打光方式（光从上面来，
    /// 顶边最亮）。芯片 2026-08-04 改成胶囊之后这条线站不住了：胶囊没有"顶边"，
    /// 那条横线两头会插进左右两个半圆里，看着像贴歪了一道贴纸。改成整圈同亮度，
    /// 和用户给的那张参考截图一致（那上面也是一圈匀的浅色边）。
    static let tabActiveStroke = Color.white.opacity(0.13)

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

    // MARK: - 岛的外沿

    /// 岛的外沿是三层，**量自用户给的 macOS 26 系统窗口截图**（@2x，2026-08-04）。
    ///
    /// 从里往外：
    ///
    /// | 层 | 截图里 | 换算 |
    /// |---|---|---|
    /// | 窗口底色 | `(41,44,51)` | 那是他们终端的主题色，不是系统给的 |
    /// | 亮线 | 2px `(84,86,92)` | **1pt 白色 20%** —— 三个通道各自算出 0.201/0.199/0.201 |
    /// | 黑线 | 1px `(1,3,4)` | **0.5pt 近乎纯黑** |
    /// | 阴影 | 侧面往外 54px 化完，贴边处把壁纸压暗 35% | **约 27pt，峰值黑 0.7**（贴边处是峰值的一半） |
    ///
    /// **这三层之前上过又拿掉，当时的理由是「岛是纯黑的，描边读起来是灰框
    /// 不是高光」——那次栽在只上了描边。** 亮线之所以是高光，靠的是它外面
    /// 还有一条黑线把它和阴影隔开；黑线内侧挨着的是亮线而不是岛体，所以
    /// 岛体是不是纯黑并不影响它显不显。三层必须一起上，缺一样就退回灰框。
    ///
    /// **两处不上外沿**（用户 2026-08-04 看完实机定的，见 `IslandShell.edges`）：
    /// 顶边不描（它压在屏幕物理上沿，只露得出内侧半条，是刘海底下一道亮痕）；
    /// idle 态整套不上（那时候岛就是刘海本身，描一圈就成了浮在屏幕顶上的黑条）。
    static let edgeHighlight = Color.white.opacity(0.20)
    /// 亮线画在轮廓**内侧**，这是它露出来的宽度。
    static let edgeHighlightWidth: CGFloat = 1
    static let edgeLine = Color.black
    /// 黑线画在轮廓**外侧**，这是它露出来的宽度。
    static let edgeLineWidth: CGFloat = 0.5
    static let edgeShadow = Color.black.opacity(0.70)
    static let edgeShadowRadius: CGFloat = 18
    /// 阴影往下偏：截图里左右两侧 27pt 就化干净了，底下到裁切边都没化完。
    static let edgeShadowOffsetY: CGFloat = 6

    /// 画布要在岛的左、右、下各多留出这么多 —— **阴影得在窗口边界之内化干净**。
    ///
    /// 岛的画布就是一块 `NSWindow`，窗口画不到自己 frame 之外去。留的地方不够，
    /// 阴影会被**齐齐切掉**：剩下的那半截贴着岛，外沿是刀切的直线，
    /// 读起来是岛外面又套了一条黑边。
    ///
    /// 用户 2026-08-04 报的「拖到一定大小（大），会出现一条不一样的黑边」就是它。
    /// 量他那张截图：岛正好停在最大宽度上，画布两侧只剩 8pt（那时候只按内凹半径
    /// 留），阴影在 8pt 处被截断 —— 壁纸亮度在一个像素之内从 76% 跳回 100%，
    /// 底下同理（31px 处一跳）。岛小的时候画布富余，阴影化得完，所以只有拖大才看得见。
    ///
    /// `radius * 2 + offsetY` 是这个高斯的保守包络（18pt 的阴影实测约 27pt 化完，
    /// 底边再算上下偏那 6pt）。**跟着阴影参数走、不写死** —— 阴影调浓调大时
    /// 这里自己会跟上，不然就是再切一次。
    static var edgeShadowMargin: CGFloat { edgeShadowRadius * 2 + edgeShadowOffsetY }

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

    /// tab 换位时邻居让开、松手时芯片归位。
    ///
    /// 比 `morph` 快一档：那个是整块岛变形，这个是一个芯片挪一格，
    /// 用 0.38 秒的簧会让人觉得列表在拖泥带水。阻尼给到 0.86 是不要回弹 ——
    /// tab 的位置是用户刚排的，弹一下像是没排准。
    static let tabSlide = Animation.spring(response: 0.24, dampingFraction: 0.86)
}
