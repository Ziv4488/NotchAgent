# Agent 灵动岛 · 设计文档

日期：2026-07-30
状态：已评审，待实现

## 1. 目标

一个常驻 macOS 刘海区域的灵动岛，作为 AI Agent 的统一入口与仪表盘。它做两件事：

1. **启动并操作 Claude Code 任务** —— 交互体验与在终端里直接用 `claude` 完全一致
2. **收纳第三方 AI 桌面 app**（ChatGPT、Claude、Cursor、终端等）—— 把它们的真实窗口贴附到岛下方

平时它只占刘海本身的空间；有任务在跑时显示一行状态；任务完成时弹出提醒；点击才展开出完整内容和输入框。

### 不做什么

- 不自己实现 agent loop，不直连 Anthropic API
- 不在岛里复制一套权限确认 UI（授权只在终端里发生）
- 不做守护进程模式（接口预留，作为后续设置项）
- 不在副屏显示（只在主屏）

## 2. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 语言 / UI | Swift，AppKit + SwiftUI | 三个难点（刘海窗口层级、PTY 终端、辅助功能贴附）都有成熟原生方案；常驻 app 对内存和耗电敏感 |
| 终端 | SwiftTerm | macOS 上可用的成熟终端模拟器，支持本地 PTY 进程 |
| app 形态 | `LSUIElement`（无 Dock 图标），不开沙盒 | 需要起子进程、读用户目录、调用辅助功能 API |
| 分发 | 本地构建（Xcode / xcodebuild） | 个人使用，暂不考虑公证与上架 |

已否决的方案：Electron + xterm.js（常驻内存 200MB+、贴附仍需写 native 模块）；Tauri（刘海层级与 AX 贴附都要写 Rust/ObjC 桥接，坑比原生多）。

## 3. 交互形态

### 3.1 四个状态

所有尺寸在运行时从屏幕几何推导，不写死：菜单栏高度取 `NSScreen.safeAreaInsets.top`，刘海实际宽度由 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 之间的空隙算出。

| 状态 | 尺寸 | 内容 | 进入条件 |
|---|---|---|---|
| `idle` | 刘海宽 + 左右各 4pt，高 = 菜单栏高 | 无内容。仅沿边缘微微浮起：顶部 0.5pt 高光 + 极淡外阴影 | 无任务在跑且无未读 |
| `running` | 刘海宽 + 左右各 110pt，高 = 菜单栏高 | 左侧：状态点 + 会话名。右侧：当前动作 + 计时 | 至少一个任务在跑 |
| `notice` | 宽度取「`running` 宽度」与「tab 条内容所需宽度」中的较大者，上限为 `expanded` 宽度；高 = 菜单栏高 + tab 条高 | 只有 tab 条。完成的 tab 高亮且图标带绿色对勾，仍在跑的显示黄点。**常驻，不自动收起** | 收到某个会话的 `Stop` 事件 |
| `expanded` | 宽默认 560pt（可拖拽调整并记住），高 = 菜单栏高 + tab 条 + 内容区 + 输入框 | tab 条 + 内容区 + 输入框 | 用户点击岛 |

**几何细节**：底部圆角 12pt，上沿两侧内凹拐角半径 8pt。内凹拐角用自定义 SwiftUI `Shape`（两段圆弧）绘制，因此圆角变化时连续变形。状态切换用 spring 动画同时插值宽、高、圆角。

**悬停行为**：鼠标划过只做轻微高亮表示可点，**不展开、不显示预览**。必须点击才进入 `expanded`。

**通知态累积**：多个任务陆续完成时，`notice` 保持展开，所有未读 tab 都带对勾。点开某个 tab 清除该 tab 的未读；全部清除后回落到 `running` 或 `idle`。

### 3.2 展开态布局

单面板 + 标签页。顶部状态带（避开物理刘海，左右分置）→ tab 条 → 内容区 → 输入框。

一次只显示一个 tab 的内容：

- **CLI tab**：内容区是 SwiftTerm 终端视图，底部是输入框
- **app tab**：内容区和输入框整体不绘制，只保留状态带 + tab 条，第三方 app 的真实窗口紧贴 tab 条下方、同宽、圆角对齐

tab 条末尾是 `＋`，进入新建流程。

### 3.3 新建任务

点 `＋` → 岛内显示：

1. **项目列表**：从 `~/.claude/projects/` 的目录名还原出真实路径，按最近修改时间排序，最多显示 8 条。列表末尾一项「选择其他目录…」调 `NSOpenPanel`。也支持把文件夹拖到岛上
2. 选定目录后聚焦**指令输入框**
3. 回车 → 创建 `CLISession`，切到新 tab，`Esc` 取消

同一个列表里，已有历史会话的目录额外提供「继续上次会话」（走 `claude --resume`）。

不做全局快捷键唤起与目录自动推断 —— 目录必须明确，避免 Agent 在错误的地方动手。

### 3.4 降级场景

| 场景 | 行为 |
|---|---|
| 前台 app 全屏 | 刘海区被系统占用，岛隐藏。仅在收到 `Stop` 或 `Notification` 事件时用系统通知兜底 |
| 无刘海的 Mac / 外接显示器为主屏 | 同一套渲染，去掉内凹拐角，宽度基准换成固定值，呈现为屏幕顶部居中的浮条 |
| 屏幕配置变化、睡眠唤醒 | 重新测量几何并重建窗口 |

## 4. 架构

### 4.1 模块

| 模块 | 职责 | 依赖 |
|---|---|---|
| `NotchWindow` | 一个 `NSPanel`：层级压在菜单栏之上、跨 Space、跟随刘海几何、透明区不接收鼠标事件。只负责窗口，不涉及内容 | AppKit |
| `IslandShell` | SwiftUI 视图层：四态渲染、形变动画、内凹拐角 `Shape`、tab 条、通知条、新建表单。纯展示，状态由外部注入 | SwiftUI |
| `SessionKit` | 会话抽象层（详见 4.2）。`AgentSession` 协议 + `CLISession` / `AppSession` 两个实现 + `SessionStore` | Foundation |
| `StatusFeed` | 消费 hook 事件，产出收起态的状态文案与 tab 徽标 | SessionKit |
| `WindowAttach` | 基于 `AXUIElement` 的第三方窗口贴附、隐藏、恢复 | ApplicationServices |
| `ProjectRegistry` | 扫描 `~/.claude/projects/` 还原历史目录并排序；手选目录 | Foundation |
| `Preferences` | 悬停行为、展开宽度、第三方 app 预设、tab 顺序、`claude` 可执行路径 | Foundation |

模块间只通过上表声明的接口通信。`IslandShell` 不认识 PTY，`SessionKit` 不认识 SwiftUI。

### 4.2 会话抽象

```swift
protocol AgentSession: AnyObject, Identifiable {
    var id: SessionID { get }
    var title: String { get }
    var workingDirectory: URL? { get }
    var status: SessionStatus { get }        // .starting .running .waiting .finished(Int32) .failed
    func start() throws
    func write(_ text: String)               // CLI: 写入 PTY；App: 无操作
    func resize(cols: Int, rows: Int)        // CLI: PTY 窗口尺寸；App: 无操作
    func terminate()
}
```

`SessionStore` 持有会话数组，管理 tab 顺序、当前选中 tab、未读标记。

这层抽象就是后续换守护进程模式的接缝：v1 的 `CLISession` 直接持有子进程；将来的 `DaemonSession` 通过 IPC 连到外部进程，`IslandShell` 无需改动。

### 4.3 数据流

```
用户点 ＋ → ProjectRegistry 给出目录 → SessionKit.spawn(dir, prompt)
                                          │
                                          ├─ PTY ────→ SwiftTerm ────→ IslandShell 内容区
                                          │
                                          └─ hooks ──→ Unix socket ──→ StatusFeed ──→ IslandShell
                                                                                      (running / notice)
```

两条路完全独立：hook 通道断开时 PTY 交互照常；PTY 崩溃时 hook 也能报告最终状态。

## 5. Claude Code 集成

### 5.1 启动

`CLISession` 通过伪终端启动 `claude`，工作目录为选定目录，首个指令作为参数传入。跑的是标准交互式会话，因此斜杠命令、`Esc` 中断、权限确认、`/clear` 等全部原生可用 —— 这是「与终端体验一致」的实现方式。

**`claude` 可执行文件定位**：GUI app 继承的 PATH 不含用户 shell 的 PATH。启动时执行 `$SHELL -ilc 'echo $PATH'` 解析出真实 PATH 并在其中查找；找不到时在设置里让用户手填绝对路径，并把结果记入 `Preferences`。

### 5.2 状态采集

启动时附加 `--settings <bundle 内的 island-hooks.json>`，其中只注册 hooks，不修改用户的 `~/.claude/settings.json`。hook 命令指向 bundle 内一个转发小程序，它把 stdin 收到的 hook JSON 原样写入 app 监听的 Unix domain socket，事件中的 `session_id` 用于对应 tab。

| Hook | 岛的反应 |
|---|---|
| `SessionStart` | 记录 `session_id` 与 tab 的绑定关系 |
| `PreToolUse` / `PostToolUse` | 更新收起态文案：「读 session.ts」「改 session.ts」「跑 npm test」 |
| `Notification` | 岛转琥珀色，表示 Agent 在等待用户 |
| `Stop` | 进入 `notice` 态，该 tab 打未读标记 |

**已验证可行**（Claude Code 2.1.220，见第 11 节）：`--settings` 与用户设置**合并**而非覆盖，且不同来源的 hooks **叠加**触发。因此一份只含 hooks 的文件不会干扰用户的全局或项目级配置，无需独立 `CLAUDE_CONFIG_DIR`。

`SessionStart` 事件的 payload 含 `cwd`、`session_id`、`source`、`transcript_path`。`transcript_path` 指向该会话的 JSONL 记录，作为 hook 通道失效时的备用状态来源（不在 v1 实现）。

**授权只在 PTY 中发生。** 岛不提供第二套「允许 / 拒绝」按钮，`Notification` 事件仅用于点亮岛、引导用户去看终端。这避免了两套 UI 状态不一致。

### 5.3 终端宽度

展开态默认 560pt，配 11pt 等宽字体约 80 列，Claude Code 的 diff 与表格排版正常。允许拖拽左右边缘调宽并记住宽度。收起态尺寸与终端宽度无关，保持最小。

PTY 的 cols/rows 跟随终端视图实际尺寸变化，通过 `resize` 下发。

### 5.4 生命周期

v1：任务是 app 的子进程。退出 app 时若有任务在跑，先弹确认对话框；确认后终止全部子进程。会话记录留在 `~/.claude`，下次可通过 `＋` 列表的「继续上次会话」用 `--resume` 接回。

守护进程模式（任务在 app 之外存活、重开可重新接管）作为后续的设置项，接口已在 `SessionKit` 预留。

## 6. 第三方 app 贴附

### 6.1 注册

不硬编 bundle id。用户在设置里选择一个 `.app`，岛读出其 bundle id 存入 `Preferences`。内置若干开箱预设（ChatGPT、Claude、Cursor、终端），与自定义走完全相同的代码路径。

### 6.2 贴附流程

切到某个 app tab 时：

1. 该 app 未运行 → 启动它并等待主窗口出现
2. 通过 `AXUIElement` 取最前面的主窗口，**记录其原始 frame**
3. 设置 `AXPosition` / `AXSize` 到岛内容区对应的屏幕坐标
4. 激活该 app 到前台（否则窗口会被其他 app 遮挡）；岛的面板层级高于普通窗口，不会被盖住

切走或收起岛时调用 `NSRunningApplication.hide()`（等价 ⌘H），再次展开时 unhide 并重新定位。

### 6.3 恢复原状

移除该 tab、或岛退出时，**必须把窗口恢复到步骤 2 记录的原始 frame**。这是硬性要求 —— 否则用户的窗口布局会被永久破坏。

### 6.4 权限与降级

| 情况 | 行为 |
|---|---|
| 未授予辅助功能权限 | 首次用到时通过 `AXIsProcessTrustedWithOptions` 请求。未授权时 app tab 显示「需要权限 →」占位卡，点击跳转系统设置。**CLI tab 不受任何影响** |
| 目标窗口有最小尺寸限制、压不到岛的宽度 | 把岛加宽以匹配该窗口的最小尺寸，而不是硬压导致窗口错位 |
| 目标 app 被用户手动退出 | tab 转「未运行」态，点击可重新启动 |
| 多窗口 app | v1 只接管最前面的主窗口 |

## 7. 持久化

| 数据 | 位置 |
|---|---|
| 悬停行为、展开宽度、第三方 app 预设、tab 顺序、`claude` 路径 | `UserDefaults` |
| tab 骨架（tab 列表及其类型、目录） | Application Support 下一个 JSON |
| 会话内容 | **不自行存储**，由 `~/.claude` 负责，岛只引用 session id |

重启后 tab 骨架恢复，CLI tab 显示为「已结束 · 可继续」。

## 8. 错误处理

| 情况 | 处理 |
|---|---|
| 找不到 `claude` 可执行文件 | 按 5.1 的 PATH 解析流程处理；最终失败时在设置中引导手填路径 |
| PTY 子进程崩溃或非零退出 | tab 上显示退出码与「重启」按钮，绝不静默消失 |
| hook socket 断开或转发程序失败 | 状态降级为「运行中（无详情）」，PTY 交互不受影响 |
| AX 调用阻塞 | AX 是同步阻塞 API，目标 app 无响应会冻结 UI。所有 AX 调用在后台队列执行并设超时，超时后报「贴附失败」 |
| 屏幕配置变化、睡眠唤醒 | 重新测量几何并重建窗口 |
| 展开时键盘焦点 | 面板为 `.nonactivatingPanel`，`canBecomeKey` 仅在 `expanded` 状态返回 true；展开时 `makeKey`，收起时交还焦点。行为类比 Spotlight |

## 9. 测试策略

把难以自动化的部分挤到边缘，核心逻辑保持可单测。

| 目标 | 方式 |
|---|---|
| `SessionKit` | 注入假 PTY（跑 `cat` 等脚本）测启动、退出码、resize、终止。不依赖真实 `claude` |
| `StatusFeed` | 用真实 hook payload 的 JSON 固件驱动，纯单测覆盖状态派生 |
| `NotchWindow` 几何 | 屏幕几何抽成 protocol，注入假数据覆盖 14"、16"、无刘海、外接屏四种情形 |
| `IslandShell` 状态机 | 写成纯函数 `(state, event) -> state`，单测覆盖四态间所有跃迁；视觉效果靠肉眼与快照 |
| `WindowAttach` | 自动化不现实。维护手动测试清单：对 ChatGPT / Claude / Cursor / 终端各执行「贴附 → 收起 → 移除 tab → 验证窗口回到原始 frame → 撤销权限后的降级」 |
| 端到端冒烟 | 脚本启动真实 `claude` 跑一个 `echo hello` 级任务，断言 `Stop` hook 抵达且岛进入 `notice` 态 |

## 10. 实现分期

两部分可以独立交付，建议分两期，各自都是能用的东西：

- **第一期 —— 岛壳 + Claude Code**：`NotchWindow`、`IslandShell` 四态、`SessionKit` 的 `CLISession`、`StatusFeed`、`ProjectRegistry`。做完就已经能脱离终端启动和操作任务
- **第二期 —— 第三方 app 贴附**：`WindowAttach`、`AppSession`、辅助功能权限引导、app 预设设置

第一期不实现 `AppSession`，但 `AgentSession` 协议按第 4.2 节定义完整，tab 条已支持异构 tab 类型。

## 11. 实现前的验证事项

### 11.1 `--settings` 注入 hooks —— 已验证通过

环境：Claude Code 2.1.220，macOS 26.5。复现脚本 `scripts/spike-hooks.sh`。

| 问题 | 结论 |
|---|---|
| hook 是否触发 | `SessionStart`、`PreToolUse`、`PostToolUse`、`Stop` 全部触发。`Notification` 在该轮无需用户介入，未触发（符合预期） |
| payload 是否带 `session_id` | 每个事件都带。`SessionStart` 的字段为 `cwd` / `hook_event_name` / `session_id` / `source` / `transcript_path` |
| 与用户设置是合并还是覆盖 | **合并**。只含 hooks 的文件注入后，用户设置里的 `model: opus` 仍然生效 |
| CLI 侧设置能否覆盖同名键 | 能。文件里写 `model: haiku` 时该轮确实用 haiku，即 CLI 侧对它定义的键优先 |
| 项目级已有的 hooks 会否被顶掉 | **不会，叠加触发**。项目 `.claude/settings.json` 的 `PostToolUse` 与注入的 `PostToolUse` 同时收到事件 |

**结论**：方案按 5.2 原样实施，不需要独立 `CLAUDE_CONFIG_DIR`。

### 11.2 非激活面板中的键盘焦点 —— 待验证

`.nonactivatingPanel` 动态切换 `canBecomeKey` 后 SwiftTerm 能否正常接收按键，**中文输入法**是重点。见实现计划 0.4。

### 11.3 第三方 app 的 AX 响应 —— 待验证

ChatGPT 等 Electron app 对 `AXPosition` / `AXSize` 的响应情况与窗口最小尺寸。见实现计划 0.5。
