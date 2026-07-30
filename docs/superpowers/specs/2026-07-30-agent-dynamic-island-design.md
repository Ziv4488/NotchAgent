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
| `idle` | 刘海宽 + 左右各 80pt，高 = 菜单栏高 | 左侧：状态点 + 最近一个会话名（一个会话都没有时只写 `NotchAgent`）。右侧：会话数 | 无任务在跑且无未读 |
| `running` | 刘海宽 + 左右各 88pt，高 = 菜单栏高 | 左侧：状态点 + 会话名。右侧：本轮计时 + 会话数 | 至少一个任务在跑 |
| `notice` | 宽度取「`running` 宽度」与「tab 条内容所需宽度」中的较大者，上限为 `expanded` 宽度；高 = 菜单栏高 + tab 条高 | 只有 tab 条。完成的 tab 高亮且图标带绿色对勾，仍在跑的显示黄点，等你回话的显示蓝色问号。**常驻，不自动收起** | 收到某个会话的 `Stop` 事件，或某个会话开始等你回话 |
| `expanded` | 宽默认 560pt、内容区默认 320pt，**两者都可拖拽调整并记住**；高 = 菜单栏高 + tab 条 + 内容区 + 用量条 + 输入框 | tab 条 + 内容区 + 用量条 + 输入框 | 用户点击岛 |

**承载岛的 `NSPanel` 一开就是这块屏幕上岛能达到的最大尺寸，之后全程不动** —— 既不随状态变，也不随拖拽变。岛在这块固定画布里变形。理由有两条：状态切换时每帧改 `NSWindow` 的 frame 会抖；而岛是相对屏幕中线对称的，拖宽时窗口原点要左移、内容要在窗口里保持居中，这两件事一旦落到不同的绘制事务里就会看见一帧错位。代价是一大块透明画布压在屏幕上半部 —— 因此 `NotchHostingView` 那套「只有岛的轮廓内才吃鼠标事件」的命中测试是**必需**的，不是优化。

**几何细节**：底部圆角 12pt，上沿两侧内凹拐角半径 8pt。内凹拐角用自定义 SwiftUI `Shape`（两段圆弧）绘制，因此圆角变化时连续变形。状态切换用 spring 动画同时插值宽、高、圆角。岛体不描边、不投影 —— 两者都试过：描边在纯黑岛体上读起来是灰框，投影落在透明画布上是一层洗不掉的黑雾。

**左右两侧是定宽的，不是弹性的。** 状态带按 `(岛宽 − 刘海宽) ÷ 2` 把左右两半各自钉死，中间原样留给物理刘海。用 `Spacer(minLength:)` 只能保证下限，一侧内容超长就会把中缝压掉、文字从刘海底下开始。定宽的代价是超长内容只能截断 —— 但在一行高的状态带里，截断本来就是对的。每侧的文字预算约 60pt，11pt 系统字下约 10 个英文字符 / 5 个汉字。

**状态点的四种形态**：琥珀色慢呼吸 = 在跑，蓝色快闪 = 停下来等你回话，绿色 = 本轮完成，灰色不发光 = 会话已结束。光靠颜色分不出「在跑」和「卡住等确认」，所以用闪烁频率区分 —— 后者不理它就一直卡着，必须更抓眼。「等你回话」和「完成未读」一样会把岛推到 `notice`。

**代价：岛比刘海宽就会盖住菜单栏。** 本机实测刘海只有 185pt，刘海左侧留给应用菜单的区域是 0–663pt。`idle` 宽 345pt，左边缘落在 583pt，因此会永久盖住 583–663 这 80pt —— 菜单多的 app（Xcode、终端）最后一两个菜单会被压住；菜单少的 app（访达、Safari）够不到那里，无影响。`running` 更宽，盖得更多。这是「岛上常驻信息」的固有代价，唯一的调节手段是 `IslandConstants.idleSideBleed` / `runningSideBleed`。

**悬停行为**：鼠标划过只做轻微高亮表示可点，**不展开、不显示预览**。必须点击才进入 `expanded`。

**焦点行为**：`idle` / `running` / `notice` 三态都不抢焦点。但 `expanded` 会 —— 展开时岛必须激活自己，当前前台 app 因此失去焦点；收起时焦点交还给展开前那个 app。这是 macOS 的硬约束（见 11.2），行为与 Spotlight 一致。

**通知态累积**：多个任务陆续完成时，`notice` 保持展开，所有未读 tab 都带对勾。点开某个 tab 清除该 tab 的未读；全部清除后回落到 `running` 或 `idle`。

### 3.2 展开态布局

单面板 + 标签页。顶部状态带（避开物理刘海，左右分置）→ tab 条 → 内容区 → 用量条 → 输入框。

一次只显示一个 tab 的内容：

- **CLI tab**：内容区是 SwiftTerm 终端视图，下面是用量条和输入框
- **app tab**：内容区、用量条和输入框整体不绘制，只保留状态带 + tab 条，第三方 app 的真实窗口紧贴 tab 条下方、同宽、圆角对齐

tab 条末尾是 `＋`，进入新建流程。

**用量条**（输入框上方一行，22pt 高）。等价于终端里 Claude Code 自己那条 statusline，但常驻可见：

| 位置 | 内容 |
|---|---|
| 左 | `ctx` / `5h` / `周` 三条细额度条 + 百分比。超过 80% 转琥珀色 |
| 右 | 子代理数（为 0 时不显示）、当前权限模式 |

模式芯片显示当前档位与快捷键提示 `⇧⇥`，点击或按 ⇧Tab 在 `Manual → Accept edits → Plan → Auto` 之间轮换，非 Manual 档位用蓝色标出 —— 用户得知道自己现在在什么模式下按回车。**档位名称照抄 Claude Code 自己的模式选单，不翻译**：岛显示的词必须和用户在终端里看到的是同一个，否则「我现在在哪个模式」这件最要紧的事会对不上。

> 第 2 阶段接真实数据：额度三项走 `/usage` 或 statusline，模式与子代理走 hook，填进 `SessionUsage`。⇧Tab 届时应原样喂给 PTY、由 Claude Code 自己切，岛只反映结果。

**输入框的发送键在会话运行时变成停止键**（红底方块）。中断是运行中最需要在手边的动作，不该让用户去别处找。第 2 阶段这里给 PTY 发 Esc / SIGINT，与终端里按 Esc 等效。用户自己按的停止不标未读 —— 人就在跟前看着，不该再催他。

**拖拽调整尺寸**：展开态的左右两条竖边改宽度、底边改高度、两个下角同时改两者。只做下角是不够的 —— 调整窗口的直觉是去抓侧边，只有角能拖会让人以为坏了。可拖这件事只用**底边中央一条短横条**提示，加上光标移上来时的形状变化；下角**不画任何标记**：岛的下角是 12pt 圆角、直接贴着桌面，画一对直角线读起来是「岛外面还套了个框」，比没有更糟。宽度可拖范围 420pt 到「屏幕宽 − 160」，内容区高度 160pt 到「屏幕高 × 0.85 − 固定开销」。

**拖拽必须用鼠标的屏幕绝对坐标算目标尺寸，不能用手势的相对位移。** 手柄贴着岛边排，岛一变宽手柄就跟着移动，手势的局部坐标系也跟着移动 —— 拿那个坐标系里的位移去加宽度，会形成「变宽 → 坐标系移动 → 位移变小 → 回缩」的振荡，表现为拖动时剧烈闪烁，极端情况下还能把岛甩出中线。按下时记住鼠标与被拖边缘的差值，全程用 `NSEvent.mouseLocation` 反算目标尺寸，这两个毛病一起消失。

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
    var status: SessionStatus { get }        // .starting .running .waiting .idle .finished(Int32) .failed
    func start() throws
    func write(_ text: String)               // CLI: 写入 PTY；App: 无操作
    func resize(cols: Int, rows: Int)        // CLI: PTY 窗口尺寸；App: 无操作
    func terminate()
}
```

`.idle` 是实现时加的第六档：`Stop` hook 表示「这一轮结束」，进程仍然活着。没有它就只能在「还在干活」和「进程已退出」之间二选一，两个都是错的。

**两个 SwiftTerm 的坑，都必须在 `CLISession` 里绕过**：
- `processTerminated(exitCode:)` 交出来的不是退出码，是 `waitpid` 的**原始状态字**（`exit 3` → 768）。要自己解 `WEXITSTATUS`；被信号杀掉的按 shell 惯例记成 `128 + 信号`。
- `LocalProcess.terminate()` 发完 SIGTERM 就直接收尾，**一次都不调 delegate**。光等回调的话，被关掉的 tab 会永远停在「运行中」，状态得自己置。

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
| `Notification` | 该 tab 转「等你回话」（蓝色快闪 + 蓝色问号角标），岛进 `notice` |
| `Stop` | 进入 `notice` 态，该 tab 打未读标记 |

**已验证可行**（Claude Code 2.1.220，见第 11 节）：`--settings` 与用户设置**合并**而非覆盖，且不同来源的 hooks **叠加**触发。因此一份只含 hooks 的文件不会干扰用户的全局或项目级配置，无需独立 `CLAUDE_CONFIG_DIR`。

`SessionStart` 事件的 payload 含 `cwd`、`session_id`、`source`、`transcript_path`。`transcript_path` 指向该会话的 JSONL 记录，作为 hook 通道失效时的备用状态来源（不在 v1 实现）。

**授权只在 PTY 中发生。** 岛不提供第二套「允许 / 拒绝」按钮，`Notification` 事件仅用于点亮岛、引导用户去看终端。这避免了两套 UI 状态不一致。

**这条约束反过来决定了键盘焦点归谁。** 权限选单要用 `1`/`2`/`3` 回答、模式要用 ⇧Tab 切、中断要用 `Esc`、斜杠命令要用方向键选 —— 全是 TUI 自己在处理的按键。焦点只要不在终端上，这些就全废了。所以：**CLI tab 有活着的会话时，键盘直接归终端视图，岛不绘制自己的输入框**（3.2 里那个输入框只服务于新建流程和已结束的会话）。停止键搬到用量条右端。SwiftTerm 的 `TerminalView` 实现了 `NSTextInputClient`，中文输入法不受影响。

**实测补充（Claude Code 2.1.220，探针 A/A′）**：
- payload 里带 `permission_mode`（`default` / `acceptEdits` / `plan` / `bypassPermissions`）。原计划是让用户在岛上点模式芯片再想办法喂给 CLI，**方向就此反过来：以 CLI 为准，岛只负责显示**。点芯片和按 ⇧Tab 都只是把 `ESC [ Z` 送进 PTY，岛等事件回来才更新。
- `Notification` 带 `notification_type`（实测 `permission_prompt`），据此把「在等你批权限」和「闲置提醒」分开 —— 后者不该让岛快闪催人。
- payload 还有 `effort` / `prompt_id` / `background_tasks` / `session_crons` 等文档未列的字段。**所以解码手写、只取需要的键**，用严格 `Codable` 早晚会被某次升级弄哑。
- 子代理没有专门的 hook，它就是 `Task` 工具：`PreToolUse` +1、`PostToolUse` −1。

**事件怎么绑回 tab**：`session_id` 是 Claude Code 自己生成的，`SessionStart` 之前无从得知。所以 spawn 时注入 `NOTCH_TAB=<tab id>`，hook 命令会继承（已实测），转发时作为**第一行**发出，JSON 跟在后面。第一行不像 UUID 就当整包都是 JSON，再按 `cwd` 兜底匹配。

**转发端用系统自带的 `/usr/bin/nc`，不带自己的小程序。** 原计划要在 bundle 里放一个 `hook-forward`，那需要多一个 Xcode target 和一条拷贝构建阶段。`nc -U` 一次往返实测 30ms，socket 不存在时 25ms 内失败退出，满足「绝不阻塞 Claude Code」。
**但绝不能加 `-N`**：手册上它是「stdin EOF 后关写端」，实测这台 macOS 的 nc 一见 `-N` 就报 `invalid tcp adaptive write timeout value` 并以 1 退出，一个字节都发不出去 —— 而且退得飞快，只看耗时会误判成成功。

**监听端用裸 BSD socket，不用 Network.framework。** `NWListener` 配 `requiredLocalEndpoint: .unix(path:)` 会被系统拒（`setsockopt SO_NECP_LISTENUUID failed [22]`），监听建得起来但一个连接都收不到。

### 5.2b 用量三项从哪来

hook payload 里**一个都没有**，三个数字各有各的源头。口径必须和 Claude Code 自己那条 statusline 逐字一致 —— 岛上和终端里差一点点，比不显示更糟：用户会开始怀疑该信哪个。

| 数字 | 来源 | 备注 |
|---|---|---|
| 上下文 | `SessionStart` 给的 `transcript_path`，读最后一条 assistant 消息的 `usage`，`input + cache_read + cache_creation` ÷ **200,000** | 分母是自动压缩阈值，**不是**模型的上下文窗口（Opus 5 报 1,000,000）。用后者算出来的数和终端里对不上。只读文件尾部，transcript 会长到几十兆 |
| 5 小时 / 周 | `~/.claude.json` 的 `cachedUsageUtilization` | Claude Code 自己维护的缓存，不联网、不碰钥匙串 |
| 子代理 | `Task` 工具的 `PreToolUse` / `PostToolUse` 配对计数 | 没有专门的 hook |

**拿不到就显示一条横线，绝不用 0 顶替。**「额度还没动」和「不知道额度用了多少」是完全相反的两条结论，而用户会照着它决定还能不能接着干活。

`cachedUsageUtilization` 只在 Claude Code 自己需要时才刷新（比如用户开 `/usage`），实测可能是好几天前的，所以**超过 15 分钟就当不知道**。实时值唯一的来源是拿钥匙串里的 OAuth token 打 `api.anthropic.com/api/oauth/usage`；岛不这么做 —— 读用户凭据、代发网络请求，得由用户自己决定。

### 5.3 终端宽度

展开态默认 560pt，配 11pt 等宽字体约 80 列，Claude Code 的 diff 与表格排版正常。拖拽底边可调宽高并记住（见 3.2）。收起态尺寸与终端宽度无关，保持最小。

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
| 目标窗口有最小尺寸限制、压不到岛的尺寸 | **把岛加宽并加高**以匹配该窗口的最小尺寸，而不是硬压导致窗口错位。实测 ChatGPT 最小 480×600，且高度确实会被钳制（见 11.3） |
| 目标 app 被用户手动退出 | tab 转「未运行」态，点击可重新启动 |
| 多窗口 app | v1 只接管最前面的主窗口 |

## 7. 持久化

| 数据 | 位置 |
|---|---|
| 悬停行为、展开尺寸、第三方 app 预设、tab 顺序、`claude` 路径 | `UserDefaults` |
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
| 展开时键盘焦点 | 面板为 `.nonactivatingPanel`；`canBecomeKey` 与 `canBecomeMain` 都仅在 `expanded` 时返回 true。展开时 `NSApp.activate()` + `makeKey` + `makeMain` + `makeFirstResponder(终端)`，并抬高输入法候选框窗口；收起时把焦点交还给展开前的 app。四步缺一不可，详见 11.2 |

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

### 11.2 非激活面板中的键盘焦点 —— 已验证通过

结论：**可行，但需要同时满足四个条件**，缺任何一个都会表现为「打字完全没反应」。可工作的探针实现见提交 `29a1c75`。

| 条件 | 为什么 |
|---|---|
| 展开时必须 `NSApp.activate()` | macOS 只把键盘事件发给**前台 app**。非激活面板能在自己 app 内成为 key window，但 app 不在前台时键仍然进前台那个 app。Spotlight / Raycast 能打字正是因为它们弹出时激活了自己 |
| `canBecomeMain` 在展开态必须为 `true` | SwiftTerm 靠 `interpretKeyEvents` 走输入法链路插入文本，而 `NSTextInputContext` 需要窗口能成为 main 才会激活。写死 `false` 时按键事件确实进到了 app、终端也确实是 first responder，但一个字也插不进去，中文更是完全没有候选框 |
| 必须显式 `makeFirstResponder(终端)` | 否则没有视图持有焦点，按键无人接收 |
| 展开态需把输入法候选框窗口抬到岛之上 | 候选框是**本进程内**的窗口，层级固定 `20`；菜单栏在 `24`，岛必须 ≥ `25`。岛不可能同时高于菜单栏又低于候选框，只能反过来抬高候选框 |

抬高候选框的做法：在展开态监听 `keyDown`，扫 `NSApp.windows` 找出层级为 `20` 且非自建的可见窗口，把 level 设为岛的 level + 1。

**对交互的影响**（需在 3.1 体现）：展开岛会让当前前台 app 失去焦点，收起时焦点交还给展开前那个 app。这是 macOS 的硬约束，行为与 Spotlight 一致。

### 11.3 第三方 app 的 AX 响应 —— 已验证，需调整 6.4

ChatGPT（`com.openai.codex`，原窗口 1164×806）实测：

| 项 | 结果 |
|---|---|
| `AXPosition` | ✓ 完全服从，设 `(400,40)` 实得 `(400,40)` |
| `AXSize` | ✗ **只服从宽度**。设 `560×420` 实得 `560×600` —— 高度被钳到最小值 |
| 最小尺寸 | **480×600** |
| 恢复原始 frame | ✓ 精确 |

**结论**：AX 贴附方案可行，但 6.4 的兜底策略要从「加宽」改成「**加宽并加高**」—— 高度同样会被钳制。Claude 桌面 app、Cursor、终端的实测留到第 3 阶段的手动清单补齐。
