# 现在做到哪了

更新于 2026-08-04（`0961791`）。**这页只写"当前状态"，细节不搬**——
做什么去 [spec](superpowers/specs/2026-07-30-agent-dynamic-island-design.md)，
怎么做去 [plan](superpowers/plans/2026-07-30-agent-dynamic-island-plan.md)，
验收去 [manual-tests](manual-tests.md)。

## 一句话

Claude Code 会话在岛里跑通了，日常能用；第三方 app 贴附还没开工；剩下的是打磨。

## 阶段

| 阶段 | 状态 |
|---|---|
| 0 · 三个探针 | 完成，结论回写进 spec 第 11 节 |
| 1 · 岛壳（四态、几何、窗口层级、拖拽调尺寸） | 完成 |
| 2 · Claude Code 会话（PTY、hook 通道、tab、持久化、退出收尾） | 完成，日常在用 |
| 3 · 第三方 app 贴附 | **没开工**。`AXIsProcessTrusted()` 现在为真，权限那关不再挡路 |
| 4 · 打磨 | 6 项里做完 2 项，见下 |

## 跑起来

```sh
xcodebuild -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -configuration Debug build
xcodebuild test -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -destination 'platform=macOS'
./scripts/smoke.sh          # 起真 claude，端到端验 hook 事件
```

08-04 那次全绿：**354 个测试 / 37 个套件**。

## 下一步（用户排的顺序）

1. **偏好设置面板** —— 悬停行为、`claude` 路径、app 预设管理、终端主题
2. **终端配色与字体主题** —— 范围见 plan 的「4.3 的范围」
3. **全屏降级兜底** —— 岛被 `orderOut` 那段时间收到 `Stop`/`Notification` 时发系统通知
4. **终端左右二分** —— 用户说「现在拖大其实整体还是挺足够的」，排最后
5. **第 3 阶段贴附** —— 何时插队由用户定

打磨里已做完的两项：错误态 UI（08-02）、tab 条横向滚动（08-02）。

## 挂着的

- **外沿**：08-04 按用户给的 macOS 26 窗口截图改了下角（12→16）和外沿三层
  （内 1pt 白 20% + 外 0.5pt 黑 + 阴影 0.7/18pt/下偏 6）；当天晚上按实机反馈
  收了两处 —— **顶边不描线**（`NotchShape.closesTop`）、**idle 态整套不上**
  （回到 08-02 那版的纯黑一块）；两处用户都复测过了。深夜又修了一处：
  **岛拖到最大时阴影被窗口边缘齐齐切断**，留下一条外沿笔直的黑带
  （`containerFrame` 现在左右和下面各让出 `IslandTheme.edgeShadowMargin`）——
  §1.7b 等复测。**阴影浓淡好不好看只能人眼判**，§1.7 也还欠着
- **拖拽热区**：08-04 深夜按用户定的「内 4pt 外 4pt」做了，热区跨在岛的边线上，
  岛外那 4pt 由 `NotchHostingView.accepts` 单独放行。**等 §8.3b / §2.2b 复测**
  （外面点得到、再往外照旧穿透、✕ 还点得着）
- **观感批改**：13.13b（芯片改胶囊）、10.10e（结束态一个内框）用户复测过了；
  13.13（拖动时的滑动 + 不透光）还欠着。用户说「还有其他观感需要调」，
  剩下的要攒一批一起改
- **手测欠账**：清单里 176 行，划掉/带结论的约 59 行。成块欠着的是
  §10.4–10.12c（真实会话）、§11.x（收起态进度）、§12.1c–12.1e、§12b.3/12b.4、
  §13.10–13.16、§14.x（收起态浮层）。§3.1–3.5 卡在没有外接屏。
  **§8.3 第六版光标等你复测**——路线是「岛外 → 底边 → 岛内 → 底边 → 岛外」，
  要在边上来回蹭，前提先点一下岛
- 清单的记法不统一：过了的行有的划掉、有的只在旁边写日期、有的当时口头过了没回写。
  往后一律回写，不然过一阵就分不清哪些是真没测

## 拍过板不做的

守护进程模式（反过来堵上了，见 `SessionReaper`）、用量三项（Claude Code 自己的
statusline 已有）、tab 右键改名、全局快捷键、副屏与多岛、公证分发。
