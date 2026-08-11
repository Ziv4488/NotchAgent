# 现在做到哪了

更新于 2026-08-11。**这页只写"当前状态"，细节不搬**——
做什么去 [spec](superpowers/specs/2026-07-30-agent-dynamic-island-design.md)，
怎么做去 [plan](superpowers/plans/2026-07-30-agent-dynamic-island-plan.md)，
验收去 [manual-tests](manual-tests.md)。

## 一句话

常驻刘海区的通用终端（可跑 claude、grok、codex、gemini 或任何命令）。
第三方 app 贴附（第 3 阶段）已砍掉，代码在 `stage3-attach` 分支。

## 阶段

| 阶段 | 状态 |
|---|---|
| 0 · 三个探针 | 完成，结论回写进 spec 第 11 节 |
| 1 · 岛壳（四态、几何、窗口层级、拖拽调尺寸） | 完成 |
| 2 · Claude Code 会话（PTY、hook 通道、tab、持久化、退出收尾） | 完成 |
| 3 · 第三方 app 贴附 | **08-08 砍掉**，代码在 `stage3-attach` 分支。镜像方案探针确认输入转发不可行，现有贴附达不到体验标准 |
| 4 · 打磨 | 7 项里做完 5 项，见下 |

## 跑起来

```sh
xcodebuild -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -configuration Debug build
xcodebuild test -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -destination 'platform=macOS'
./scripts/smoke.sh          # 起真 claude，端到端验 hook 事件
```

08-11 全绿：**387 个测试 / 39 个套件**。

## 下一步（用户排的顺序）

1. ~~**偏好设置面板**~~ —— **08-08 做完**。菜单里的终端主题/字号/字体三项搬进
   偏好设置窗口，加上悬停行为。菜单里换成「偏好设置…（⌘,）」。
   `claude` 路径已去掉（08-08 shell-first 之后不需要了）
2. **全屏降级兜底** —— 岛被 `orderOut` 那段时间收到 `Stop`/`Notification` 时发系统通知
3. **终端左右二分** —— 用户说「现在拖大其实整体还是挺足够的」，排最后

**没排进上面这张表的**：**终端内搜索**（用户 08-05 补记）。SwiftTerm 1.15 自带引擎、
查找条和 `findNext` / `searchMatchSummary`，我们缺的只是「⌘F 送不到」那根线
（岛没有主菜单，和 ⌘C/⌘V/⌘A 当初一样）。开工前要定两件事：用它自带那条毛玻璃
查找条还是自己画、⌘F 归不归终端。细节见 plan 的「4.7 的范围」

打磨里已做完的五项：错误态 UI（08-02）、tab 条横向滚动（08-02）、
**终端配色与字体（08-05 做，08-06 收）**、**偏好设置面板（08-08）**、
**shell-first 终端（08-08）**。

### shell-first 终端（08-08）

新建 tab 起 `$SHELL -l` 而不是 `claude`。指令框里输什么就当第一条命令打进 PTY：
输 `claude 帮我重构` 就跑 claude，输 `grok` 就跑 grok，留空就是空 shell。

hook 集成不丢：`Application Support/NotchAgent/bin/claude` 是一个包装脚本，
自动给真正的 `claude` 加 `--settings`。包装脚本自己把自己从 PATH 里摘掉
再 exec 真正的 claude，不递归。PTY 环境里设了 `NOTCH_SETTINGS` 和 `NOTCH_TAB`。

**08-11 修：hook 通道其实一直是断的。** 光把 bin/ 排在 PTY 的 PATH 最前面压不住
登录 shell —— `path_helper` 会重建 PATH 把它推到末尾，用户的 `~/.zshrc` 再补一句
`export PATH="$HOME/.local/bin:$PATH"`。岛里 `claude` 解析到用户自己那个，
`--settings` 加不上，六个 hook 一条都不发。修法是 `Session/ShellShim.swift`：
zsh 的 `ZDOTDIR` 指到 `Application Support/NotchAgent/zdotdir`，四个 rc 各自先
原样跑一遍用户那一份，**再**前置 PATH。非 zsh 的 shell 没有对等切入点，维持老办法。
`ShellShimTests` 九条真起 zsh 钉着，`docs/manual-tests.md` §18.6 那行手测作废。

偏好设置面板去掉了 `claude` 路径（shell 启动不再需要找 claude）。

**08-11 修**：新建 tab 不再立刻标 `.running`（原来带命令就标，导致计时和边框在 hook
事件到达前就出现）。tab 从 `.done` 起步，由 hook 的 `userPromptSubmit` 驱动进入
`.running`，`Stop` 驱动回到 `.done` + notice 态。调试菜单去掉了四个第一阶段的假会话项。

**这一改把上面那个 shim 的病灶露了出来**：假的 `.running` 一撤，「岛不显示执行状态、
完成也不通知」当场可见 —— 那不是这次改动引入的，是 08-08 起 hook 就没到过岛上。

### 偏好设置面板（08-08）

入口在菜单栏图标菜单的「偏好设置…」（⌘,），弹出标准 NSWindow。
两个 section：

| section | 项目 |
|---|---|
| 通用 | 悬停行为（轻微高亮 / 无反应） |
| 终端 | 主题（默认 / Dracula / One Light）、字体、字号（10–18）、导入配色文件… |

原来菜单里的三个子菜单（终端主题 ▸ / 终端字号 ▸ / 终端字体 ▸）已删，
引擎（`ThemeStore` / `Preferences` / `TerminalThemeImport`）原样复用。

### 终端主题（08-05 做，08-06 收）

入口从菜单栏图标菜单搬进了偏好设置面板（08-08），引擎不变：

| 设置项 | 可选值 |
|---|---|
| 终端主题 | 默认 / Dracula / One Light ／ 导入配色文件… |
| 终端字号 | 10–18 |
| 终端字体 | 系统等宽 ／ Andale Mono、Courier New、Menlo、Monaco、PT Mono |

导入认 iTerm 的 `.itermcolors` 和 Ghostty 的主题文件（后者没有扩展名，按内容判格式）；
**缺色整份拒收**并说清缺哪一个。

两条守着的线：**默认那一档一个像素都不变**（4.3 之前没设过调色板，走的是 SwiftTerm
自带的 macOS 终端 app 那套，现在照抄进默认预设）；**岛体仍是纯黑不可配**，主题只管
内容区往里那一层。

**08-05/06 按实机反馈收了三处**：

- **第三组预设换掉**：先上的 Tokyo Night 被否（「东京夜这个颜色不要」），换成浅色的
  One Light。连带把卡片上的墨色改成**跟着底色翻** —— 原来一律是白色的某个透明度，
  那是假定了底一定是深色，白字打在 #FAFAFA 上看不见。判深浅用相对亮度，不是 HSB
  明度。**浅内容区贴着纯黑岛好不好看只能人眼判，§15.13 等你**
- **菜单从三层摊成两层**：原来是「终端字体 ▸ 字号 ▸ 数字」，用户报「一个在左一个在
  右」。根因不是摆错边 —— 子菜单往哪边弹是 macOS 按剩余空间自己定的，第三层顶到屏幕
  边就翻了。摊平之后没有第三层，也就没有翻边
- **字体列表排除 CJK 字体**：用户点名删 BIZ UDGothic、BIZ UDMincho、Lantinghei TC、
  PCMyungjo。这四个的共同点是都为 CJK 字体，`isFixedPitch` 报真只因汉字/假名/谚文
  本来全角等宽。**过滤条件写成规则而不是黑名单**（等宽且不覆盖 CJK），换台机器装了
  别的 CJK 字体照样挡得住。回滚验证过会红

## 挂着的

- **外沿只剩展开态（08-12）**：用户按实机否掉了 running 和 notice 的边框 ——
  「工作时和通知态的边框有问题，这些应该都保持 idle 态常驻无边框的状态」。
  那两态都是没人在看的时候岛自己冒出来的，一描边就成了浮在壁纸上的控件。
  `showsEdges` 现在是 `state == .expanded`，`IslandPixelTests` 一正一反两条钉着。
  **等你复测观感**：无边框的通知态在浅色壁纸上还立不立得住
- **菜单左对齐（08-12）**：退出改走自定义 selector，躲开 macOS 26 给
  `terminate:` 自动配的 SF Symbol —— 那个图标会把同一段里的「偏好设置…」
  一起顶缩进。**§17.0 等你复测**，这条只能人眼判（图标是显示那一刻才贴上的，
  代码里读 `NSMenuItem.image` 永远是 nil，写测试是假测试）
- **外沿**：08-04 按用户给的 macOS 26 窗口截图改了下角（12→16）和外沿三层
  （内 1pt 白 20% + 外 0.5pt 黑 + 阴影 0.7/18pt/下偏 6）；当天晚上按实机反馈
  收了两处 —— **顶边不描线**（`NotchShape.closesTop`）、**idle 态整套不上**
  （回到 08-02 那版的纯黑一块）；两处用户都复测过了。深夜又修了一处：
  **岛拖到最大时阴影被窗口边缘齐齐切断**，留下一条外沿笔直的黑带
  （`containerFrame` 现在左右和下面各让出 `IslandTheme.edgeShadowMargin`）——
  §1.7b 等复测。**阴影浓淡好不好看只能人眼判**，§1.7 也还欠着
- **拖拽热区**：跨在岛的边线上，内 4pt / 外 4pt —— **这个数是量出来的**（真的系统
  窗口是内 3 外 4）。08-05 第一版被用户否掉：「会点到岛外的 app」。根因不是宽度，
  是**岛外那一圈根本收不到事件** —— 非不透明窗口上点击派给谁由窗口服务器按 app
  画出来的 alpha 判，而 `.shadow` 是渲染服务器合成时加的、不进那块 alpha。
  修法是在热区上铺一层 1% 的黑（阈值实测 1/255）。**08-05 用户复测通过**
- **观感批改**：13.13b（胶囊）、10.10e（结束态一个内框）、13.13（滑动 + 不透光）、
  1.7 / 1.7b（阴影浓淡与不被切断）、2.2b（✕）、8.3b（跨边热区）用户都复测过了。
  用户说「还有其他观感需要调」，剩下的要攒一批一起改
- **手测欠账**：清单里 200 行（数出来的，含 §15 那一批；上次记的
  176 是另一种数法，别拿两个数做减法），划掉/带结论的约 59 行。成块欠着的是
  §10.4–10.12c（真实会话）、§11.x（收起态进度）、§12.1c–12.1e、§12b.3/12b.4、
  §13.10–13.16、§14.x（收起态浮层）。§3.1–3.5 卡在没有外接屏。
  **§8.3 第六版光标等你复测**——路线是「岛外 → 底边 → 岛内 → 底边 → 岛外」，
  要在边上来回蹭，前提先点一下岛。**§15.x（终端主题）整块也等你复测**
- 清单的记法不统一：过了的行有的划掉、有的只在旁边写日期、有的当时口头过了没回写。
  往后一律回写，不然过一阵就分不清哪些是真没测
- **`~/Applications/AXProbe.app` 可以删了。** 第 3 阶段已砍，探针用完了。
  删 app + 撤辅助功能授权 + 撤屏幕录制授权。源码 `scripts/spike-axprobe.swift` 已随第 3 阶段一起删

## 拍过板不做的

守护进程模式（反过来堵上了，见 `SessionReaper`）、用量三项（Claude Code 自己的
statusline 已有）、tab 右键改名、全局快捷键、副屏与多岛、公证分发、
**把用户提问带框钉在内容区顶上**（08-05 提出当天拍板不做；摸底结论和「为什么做不到
Cursor 那种跟随滚动」记在 plan 的「明确不在本计划内」）、
**第三方 app 贴附**（08-08 砍掉，镜像方案输入转发不可行，现有贴附达不到体验标准，
代码在 `stage3-attach` 分支）。
