# Agent 灵动岛 · 实现计划

对应设计文档：`docs/superpowers/specs/2026-07-30-agent-dynamic-island-design.md`
日期：2026-07-30

## 计划原则

1. **先证伪未知，再写产品代码。** spec 第 11 节那三件事任何一件不成立都要改方案，所以它们是第 0 阶段，用抛弃型探针验证，不掺进正式代码
2. **每个任务都有可验证的完成标准。** 能单测的必须单测，不能单测的写明手动验证步骤
3. **每个阶段末尾是一个能跑起来看的东西**，不是一堆还没接上的类
4. **一个任务一次提交**，提交信息写清动了什么

## 工程约定

| 项 | 决定 |
|---|---|
| 工程形态 | Xcode 工程（macOS App），使用文件系统同步组，新增 `.swift` 文件无需改 `.pbxproj` |
| Bundle ID | `com.ziv.NotchAgent`（一旦确定不再更改 —— 辅助功能权限绑定它） |
| 签名 | Personal Team 的开发签名，自动管理。**不要用 ad-hoc / Sign to Run Locally**，签名摘要每次构建都变，会导致辅助功能授权反复失效 |
| 测试系统 | Swift Testing |
| 沙盒 | 关闭（需起子进程 + 辅助功能 API） |
| 最低系统 | macOS 14 |
| 依赖 | SwiftTerm（SPM，`upToNextMajor` from 1.15.0） |
| 环境前置 | **Metal 工具链**：`xcodebuild -downloadComponent MetalToolchain`（约 690MB）。SwiftTerm 1.15 含 Metal 着色器，而 Xcode 26 默认不带该工具链，不装会构建失败并提示 `cannot execute tool 'metal'` |
| 构建命令 | `xcodebuild -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -configuration Debug build` |
| 测试命令 | `xcodebuild test -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -destination 'platform=macOS'` |

目录结构：

```
NotchAgent/
  App/                  # AppDelegate、入口、菜单栏
  Geometry/             # ScreenGeometry、NotchShape
  Window/               # NotchWindow
  Island/               # IslandState 状态机、IslandShell 视图层
  Sessions/             # SessionKit：协议、CLISession、AppSession、SessionStore
  Status/               # HookBridge、StatusFeed
  Projects/             # ProjectRegistry
  Attach/               # WindowAttach、AppRegistry
  Preferences/
  Resources/            # island-hooks.json、hook 转发程序
NotchAgentTests/
scripts/                # 冒烟脚本、探针脚本
docs/superpowers/
```

---

## 第 0 阶段 · 立项与三个探针

目标：工程能构建，且三个未知全部有结论。**这一阶段的探针代码用完即弃，结论写回 spec 第 11 节。**

### 0.1 建立工程（需要你手动做一次）

在 Xcode 里：`File > New > Project > macOS > App`，参数：

- Product Name `NotchAgent`，Organization Identifier 让 bundle id 落到 `com.ziv.notchagent`
- Interface **SwiftUI**，Language **Swift**，勾选 **Include Tests**
- 存到 `/Users/ziv/Desktop/Vibe/Agent灵动岛/`

建完后：

- Target 的 Signing & Capabilities 里**删除 App Sandbox**，Signing 选一个固定的开发证书（不要 "Sign to Run Locally"）
- `Info.plist` 加 `Application is agent (UIElement)` = `YES`
- Package Dependencies 加 `https://github.com/migueldeicaza/SwiftTerm`
- 按上面的目录结构建好文件夹，并确认它们在项目里是同步组（Xcode 16 新建的文件夹默认就是）

**完成标准**：`xcodebuild ... build` 成功；运行后 Dock 无图标、菜单栏有图标。

### 0.2 `git init` 与首次提交

- `git init`，`.gitignore` 写入 `.superpowers/`、`build/`、`*.xcuserdatad`、`.DS_Store`
- 提交现有的 spec 与本计划，以及 0.1 建出的工程骨架

**完成标准**：`git status` 干净，`git log` 有一条初始提交。

### 0.3 探针 A —— hooks 能否从参数注入

写 `scripts/spike-hooks.sh`：构造一个只含 hooks 的临时 settings 文件，hook 命令是 `cat >> /tmp/spike-hooks.log`，然后跑 `claude --settings <该文件> -p "在 /tmp 建个空文件 spike.txt"`。

要回答的问题：

1. `PostToolUse`、`Stop` 是否都触发了，payload 里有没有 `session_id`
2. 这份 settings 与 `~/.claude/settings.json` 是**合并**还是**覆盖**（在用户 settings 里放一个可识别的配置项，看它是否还生效）
3. 用户已有的 hooks 会不会被顶掉

**完成标准**：`/tmp/spike-hooks.log` 里能看到带 `session_id` 的 `PostToolUse` 与 `Stop` 事件，且上述三问都有明确答案，写回 spec 11.1。

**若合并语义不可接受**（会破坏用户既有配置）：改用给子进程设独立 `CLAUDE_CONFIG_DIR` 的方案，把结论和新方案一并写回 spec。

### 0.4 探针 B —— 非激活面板里的终端能否收键

在工程里临时加一个 `SpikeBWindow`：一个 `NSPanel`（`.nonactivatingPanel`，level 高于菜单栏），里面放 SwiftTerm 的 `LocalProcessTerminalView` 跑 `/bin/bash`。加一个开关切换 `canBecomeKey`。

要回答的问题：

1. `canBecomeKey` 为 false 时确实不抢前台 app 焦点
2. 切成 true 并 `makeKey` 后，终端能正常收英文按键、方向键、`Ctrl-C`、`Esc`
3. **中文输入法**能否正常上屏（这是最可能出问题的地方）
4. 收起（切回 false）后焦点能否交还给原来的前台 app

**完成标准**：四问全部通过，结论写回 spec 11.2。第 3 问失败时记录具体失败形态（候选框位置错、输入不上屏、还是完全不响应），因为它决定要不要给输入框单独做一个可激活的小窗口。

### 0.5 探针 C —— ChatGPT 窗口吃不吃 AX 定位

写一个临时命令行 target `spike-attach`：按 bundle id 找到 ChatGPT，取 `AXWindows` 第一个，读出原 frame，设一个新的 position/size，再读回。

要回答的问题：

1. 设置 `AXPosition` / `AXSize` 是否真的生效（Electron app 常见只吃一半）
2. 该窗口的**最小宽高**是多少（决定 spec 6.4 的加宽兜底会把岛撑多宽）
3. 恢复原 frame 是否精确
4. 对 Claude 桌面 app、Cursor、终端各跑一遍，记录差异

**完成标准**：四个 app 的结果表格写回 spec 11.3。如果 ChatGPT 完全不吃 AX 定位，在 spec 里把它降级成「只做调度、点击唤起原窗口」，其余 app 照常贴附。

### 0.6 清理探针

删除 `NotchAgent/Spike/` 整个目录，`NotchAgentApp` 恢复到最小占位。保留 `scripts/spike-hooks.sh` 作为回归工具。可工作的探针实现留在提交 `29a1c75` 里，日后要查实现细节从那里取。

---

## 第 0 阶段结果（已完成）

| 步骤 | 状态 |
|---|---|
| 0.1 工程 | 完成。构建通过，`LSUIElement`、无沙盒、最低系统 14.0 均已验证生效；签名为 Personal Team 开发证书 |
| 0.2 git | 完成 |
| 0.3 探针 A · hooks 注入 | **通过，方案不变**。见 spec 11.1 |
| 0.4 探针 B · 键盘焦点 | **通过，但暴露四个必须满足的条件**。见 spec 11.2 |
| 0.5 探针 C · AX 贴附 | **通过，但需调整 6.4 的兜底策略**。见 spec 11.3 |
| 0.6 清理 | 完成 |

三个探针改动了 spec 的四处：11.1 / 11.2 / 11.3 写入结论，3.1 补「焦点行为」小节，6.4 的兜底从「加宽」改为「加宽并加高」，第 8 节的键盘焦点一行改写为四步流程。

额外记录：SwiftTerm 1.15 需要 Metal 工具链（见工程约定），这是环境前置，换机器会再踩一次。

---

## 第 1 阶段 · 岛壳（还没有内容）

目标：一个会随假状态变形的岛，跑起来就能看。

### 1.1 `ScreenGeometry`

`Geometry/ScreenGeometry.swift`

```swift
protocol ScreenGeometryProviding {
    var menuBarHeight: CGFloat { get }      // safeAreaInsets.top
    var notchWidth: CGFloat? { get }        // nil = 无刘海
    var screenFrame: CGRect { get }
}
```

真实实现从 `NSScreen.main` 的 `safeAreaInsets` 与 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 推导刘海宽度；`FakeScreenGeometry` 供测试注入。

再写 `IslandMetrics`：把几何 + 状态映射成具体的 `CGSize` 与圆角值（spec 3.1 那张表）。

**测试**：`NotchAgentTests/IslandMetricsTests.swift` —— 覆盖 14"（刘海约 200pt）、16"、无刘海、外接屏为主屏四种几何 × 四个状态，断言宽高与圆角。无刘海时内凹拐角半径为 0。

### 1.2 `NotchShape`

`Geometry/NotchShape.swift` —— SwiftUI `Shape`：上沿两侧内凹圆弧（半径可变）、底部两个圆角（半径可变）、顶边贴齐屏幕上沿。

**验证**：一个 `#Preview` 并排渲染半径 8/12/26 三档，肉眼确认内凹拐角与主体连续、无缝隙、无毛边。半径设为 0 时退化成普通矩形（无刘海屏走这条路）。

### 1.3 `NotchWindow`

`Window/NotchWindow.swift` —— `NSPanel` 子类：

- `styleMask` 含 `.nonactivatingPanel`、`.borderless`
- `level` 高于菜单栏，`collectionBehavior` 含 `.canJoinAllSpaces` + `.fullScreenAuxiliary`
- `isOpaque = false`、透明背景、透明区域不接收鼠标（命中测试交给内容视图）
- `canBecomeKey` 由外部注入的闭包决定（探针 B 的结论落地）
- 只在主屏显示；监听 `NSApplication.didChangeScreenParametersNotification` 与睡眠唤醒通知，重新测量并重建
- 监听前台 app 是否全屏，全屏时隐藏自己

**验证**（手动清单，写进 `docs/manual-tests.md`）：切换 Space 岛跟随、进入全屏 app 岛消失退出后恢复、插拔外接屏、改分辨率、睡眠唤醒、点击菜单栏其他位置不抢焦点。

### 1.4 `IslandState` 状态机

`Island/IslandState.swift` —— 纯函数：

```swift
enum IslandState { case idle, running, notice, expanded }
enum IslandEvent { case sessionStarted, sessionProgress, sessionStopped,
                        tabOpened, click, dismiss, allRead, lastSessionEnded }
func reduce(_ state: IslandState, _ event: IslandEvent, _ ctx: IslandContext) -> IslandState
```

`IslandContext` 带「有几个在跑」「有几个未读」，因为 `notice → idle` 的回落依赖它们（spec 3.1）。

**测试**：`IslandStateTests.swift` —— 覆盖每个 (state, event) 组合。重点用例：`notice` 收到 `dismiss` 但仍有未读时留在 `notice`；未读清空且无任务在跑才回 `idle`；`expanded` 时再来 `sessionStopped` 不打断展开。

### 1.5 `IslandShell` 渲染

`Island/IslandShell.swift` + 子视图（`StatusBand`、`TabStrip`、`ContentArea`、`InputBar`、`NewTaskForm`）。这一步全部用假数据驱动。

- 四态渲染，spring 动画同时插值宽、高、圆角
- 悬停只做轻微高亮（不展开、不预览）
- 点击进入 `expanded`
- 状态带左右分置以避开物理刘海

**验证**：肉眼过四态与所有跃迁动画；`idle` 态确认是「沿边缘微微浮起」而不是一块明显的黑条；对照 `.superpowers/brainstorm/` 里定稿的 `states-v2.html` 检查视觉。

**第 1 阶段完成标准**：运行 app，用一个调试菜单手动触发事件，岛能在四态间正确变形。还没有真实会话。

## 第 1 阶段结果（代码完成，待人工验收）

| 步骤 | 状态 |
|---|---|
| 1.1 `ScreenGeometry` / `IslandMetrics` | 完成。实测本机：菜单栏 32pt、刘海宽 **185pt**（不是估的 200）。四种几何 × 四态共 17 个断言 |
| 1.2 `NotchShape` | 完成。内凹拐角方向极易画反、而深色截图上肉眼分不出来，所以改用 `Path.contains` 做几何断言钉死 |
| 1.3 `NotchWindow` / `IslandWindowController` | 完成。踩到两个 AppKit 坑，见下 |
| 1.4 `IslandState` | 完成。全组合覆盖 + 幂等性断言 |
| 1.5 `IslandShell` | 完成。四态已截图比对 `states-v2.html` |

测试：64 个，全过。手动清单见 `docs/manual-tests.md`。

### 第二轮手测反馈的修正

| 反馈 | 修法 |
|---|---|
| 收起态整体太长，一行只放得下 7 个汉字，只需要约 10 个英文字符 | `idleSideBleed` 90→80、`runningSideBleed` 110→88。每侧固定开销 20pt，文字预算 60pt |
| 左右两侧信息没被刘海分开，右侧文字从刘海里就开始了 | 状态带原本用 `Spacer(minLength: notchGap)` —— 那**只保证下限**，一侧内容超长就把中缝压掉。改成左右定宽 `(岛宽 − 刘海宽) ÷ 2`、中间放死占位 |
| 只看得到黄灯和完成，看不到「执行中」「询问」的形态 | 加 `Status.waiting`（停下来等你回话）。四态改为：琥珀慢呼吸 = 在跑、蓝色快闪 = 等你回话、绿色 = 完成、灰色不发光 = 已结束。光靠颜色分不出「在跑」和「卡住」，用频率区分 |
| 右边只要当前执行时间和开着几个窗口 | 右侧改为真实计时（`IslandTab.startedAt` + `TimelineView` 每秒刷）+ 会话数，原本的假动作文案删掉 |
| 想在对话框里看到上下文/5小时/周用量、mode（保留快捷键）、subagent | 新增 `UsageBar`（输入框上方 22pt 一行）与 `SessionUsage` 数据结构。模式芯片可点、⇧Tab 同效 |
| 说过窗口能拉大，但没看到 | 新增 `ResizeGrip`：底边中段改高、两下角改宽高（对称，位移 ×2）。`NSPanel` 跟着 `onExpandedSizeChanged` 一起长大 |
| 展开态四周还有一层黑色透明阴影 | 删掉 `.shadow(black 0.5, r12, y8)`。投影落在透明画布上是一层洗不掉的黑雾 —— 这是继描边之后第二个「加装饰反而更脏」的例子 |

顺带修掉一个自己引入的 bug：`idleSideBleed` 收窄后 `NotchAgent` 实测 64pt 放不下 54pt 的空间，**折成了两行**。空态里那个空心点不携带信息，砍掉它把宽度让给名字，并给状态带加了 `lineLimit(1)` 硬兜底 + 一条量文字宽度的回归测试。

### 两个 AppKit 坑

| 现象 | 原因与修法 |
|---|---|
| 岛被压到菜单栏下面 | `NSWindow` 在 `setFrame` 时会调 `constrainFrameRect` 把窗口推出菜单栏区域。必须覆盖它原样返回 |
| 岛的层级莫名其妙变成 3 | `isFloatingPanel = true` 的 setter 会把 `level` 改成 `.floating`(3)。**必须先设 `isFloatingPanel` 再设 `level`**，否则岛掉到菜单栏（24）下面 |

两个坑的表现一样（岛在菜单栏下面），但成因无关，得分别修。已写进 `NotchWindow` 的注释。

### 一处偏离视觉定稿

`states-v2.html` 里正在跑的 tab 用一个黄点顶替身份图标，但同一张图里选中的那个（也在跑）却显示图标 —— 定稿自相矛盾。
实现取「**图标常在、状态挂角标**」：完成未读挂绿色对勾，运行中挂琥珀点。理由是 tab 条最要紧的是「哪个是哪个」，用状态顶掉身份会让多 tab 时认不出来。

---

## 第 2 阶段 · Claude Code 会话（第一期交付）

### 2.1 `ClaudeLocator`

`Sessions/ClaudeLocator.swift` —— 执行 `$SHELL -ilc 'echo $PATH'` 解析 PATH 并查找 `claude`；结果缓存进 `Preferences`；找不到时暴露一个「需要手填路径」状态。

**测试**：把「取 shell PATH」抽成可注入的闭包，用假输出测解析、测找不到、测手填路径优先。

### 2.2 `SessionKit` 骨架

`Sessions/AgentSession.swift`（spec 4.2 的协议）、`SessionStatus`、`Sessions/SessionStore.swift`（tab 数组、顺序、当前选中、未读集合）。

**测试**：用 `FakeSession` 测增删、切换、未读标记、状态变化的通知。

### 2.3 `CLISession`

`Sessions/CLISession.swift` —— 包装 SwiftTerm 的本地进程终端：按目录 spawn `claude`（首个指令作为参数）、`write`、`resize`、`terminate`、捕获退出码并落到 `SessionStatus.finished(code)` / `.failed`。

**测试**：把可执行路径与参数作为参数注入，用脚本替身测：正常退出（`exit 0`）、非零退出（`exit 3`）、`resize` 后 `stty size` 输出正确、`terminate` 后状态正确。不依赖真实 `claude`。

### 2.4 `HookBridge`

- `Resources/island-hooks.json` —— 只含 hooks 定义，命令指向 bundle 内的转发程序
- `Resources/hook-forward` —— 几十行的小程序：读 stdin，连 Unix socket，原样写入，写不进去就静默退出（绝不阻塞 Claude Code）
- `Status/HookBridge.swift` —— app 侧监听 socket，解码事件，按 `session_id` 分发

socket 路径放 `~/Library/Application Support/NotchAgent/hooks.sock`，启动时清理陈旧 socket 文件。

**测试**：不跑 Claude Code，直接往 socket 打样本 payload，断言解码与分发正确；断开 socket 后 `hook-forward` 不挂起（用超时断言）。

### 2.5 `StatusFeed`

`Status/StatusFeed.swift` —— hook 事件 → 收起态文案（「读 session.ts」「改 session.ts」「跑 npm test」）、tab 徽标（绿点/黄点/绿勾）、`notice` 触发。

**测试**：`NotchAgentTests/Fixtures/hooks/*.json` 存真实 payload 样本（从探针 A 的日志里取），逐个断言派生结果。含一条「未知工具名」的样本，断言降级为通用文案而不是崩。

### 2.6 `ProjectRegistry`

`Projects/ProjectRegistry.swift` —— 扫 `~/.claude/projects/`，目录名还原真实路径，按 mtime 排序，最多 8 条；过滤已不存在的路径；`NSOpenPanel` 手选；岛上接收文件夹拖放。

**测试**：注入一个假的目录树（含一个已删除的路径、一个名字含特殊字符的路径），断言还原、排序、过滤、条数上限。

### 2.7 接线

- `＋` → `NewTaskForm`（项目列表 + 指令框，`Esc` 取消，`⏎` 开跑）→ 创建 `CLISession` → 新 tab 并选中
- `expanded` 的 CLI tab 渲染 `CLISession` 的终端视图；输入框内容写进 PTY
- `StatusFeed` 的输出驱动 `IslandState`（真实事件替换第 1 阶段的调试菜单）
- 已有会话的目录提供「继续上次会话」→ `claude --resume`
- 退出 app 时若有任务在跑，弹确认；确认后终止全部子进程
- tab 骨架持久化到 Application Support，重启恢复，CLI tab 显示「已结束 · 可继续」

**验证**：手动走通完整链路 —— 点 ＋、选目录、下指令、看终端跑、在岛里追问、看收起态文案变化、任务完成进 `notice`、点开清未读、退出弹确认、重启后 tab 还在。

### 2.8 冒烟脚本

`scripts/smoke.sh` —— 起真实 `claude` 跑一个 `echo hello` 级任务，断言 `Stop` 事件抵达 `HookBridge`。

**第 2 阶段完成标准（= 第一期交付）**：能完全脱离终端启动和操作 Claude Code 任务，交互与终端一致，收起态能看进度，完成有提醒。

### 第 2 阶段实现结果（2026-07-31）

自动化：168 个测试 / 17 个套件全过；`scripts/smoke.sh` 用真实 `claude` 端到端验过。

**照计划做的**：2.1 ClaudeLocator、2.2 SessionKit、2.3 CLISession、2.4 HookBridge、2.5 StatusFeed、2.7 接线、2.8 冒烟脚本。

**偏离计划的六处，都记在 spec 对应小节**：

| 处 | 计划 | 实际 | 为什么 |
|---|---|---|---|
| 2.4 转发端 | bundle 里放一个 `hook-forward` 小程序 | 用系统的 `/usr/bin/nc -U -w 1` | 省掉一个 Xcode target 和一条拷贝构建阶段。**不能加 `-N`** —— 这版 nc 一见它就报错退出，且退得飞快，只看耗时会误判成成功 |
| 2.4 监听端 | 未指定 | 裸 BSD socket，不用 `NWListener` | Network.framework 的 AF_UNIX 监听被系统拒（`SO_NECP_LISTENUUID failed [22]`），建得起来但收不到连接 |
| 2.4 绑定 | 按 `session_id` | spawn 时注入 `NOTCH_TAB`，转发时作为第一行发出 | `session_id` 在 `SessionStart` 之前无从得知。环境变量能穿透到 hook 命令（已实测） |
| 2.6 ProjectRegistry | 新写 | **复用第 1 阶段已有的 `ProjectDirectoryStore`** | 扫描、路径还原、排序、上限都已经在了 |
| 3.2 输入框 | 展开态底部常驻输入框 | **有活会话时不绘制**，键盘直接归终端 | spec 5.2 要求授权只在 PTY 里发生。焦点不在终端上，`1/2/3`、⇧Tab、`Esc`、斜杠命令全废 |
| 用量三项 | 「走 `/usage` 或 statusline」 | 上下文读 transcript、5h/周 读 `~/.claude.json` 缓存、子代理数 `Task` 工具配对 | 见 spec 5.2b。拿不到时显示横线而不是 0% |

**已知欠账**：`~/.claude.json` 里那份限额缓存只在 Claude Code 自己需要时刷新，实测常常是几天前的，于是 5h/周 多数时候显示横线。实时值要拿钥匙串里的 OAuth token 打接口 —— 涉及读用户凭据和代发网络请求，等用户拍板。

> **2026-08-01 结案：这条不做了。** 用户原话「这部份不要了，没有重复的必要」——
> 终端里 Claude Code 自己那条 statusline 已经写着上下文和模式。`UsageProbe.swift`
> 连同它的测试一起删除，`SessionUsage` 只剩 mode 与 subagents。不留半截死代码。

---

## 第 3 阶段 · 第三方 app 贴附（第二期交付）

### 3.1 `AppRegistry`

`Attach/AppRegistry.swift` —— 用户选 `.app` → 读 bundle id + 图标 → 存进 `Preferences`；内置 ChatGPT / Claude / Cursor / 终端预设，走同一条路径。

**测试**：从一个 `.app` 路径正确解析 bundle id 与显示名；bundle id 重复时不重复添加。

### 3.2 `WindowAttach`

`Attach/WindowAttach.swift`：

- 所有 AX 调用在专用后台队列执行，**每次调用都带超时**，超时返回 `.attachFailed`
- `attach(bundleID:to rect:)`：必要时启动 app 并等主窗口出现（带超时）→ 记录原始 frame → 设 position/size → 激活到前台
- `hide()` / `unhide()`
- `restore()`：恢复到记录的原始 frame
- 未授权时返回 `.needsPermission`，不弹系统权限框（由 3.4 统一处理时机）

**测试**：把 AX 操作抽到一个 `AXBridging` 协议后面，用假实现测超时路径、原 frame 记录与恢复、app 未运行时的启动等待。真机行为靠 3.6 手动清单。

### 3.3 `AppSession` 与异构 tab

`Sessions/AppSession.swift` —— 实现 `AgentSession`，`write`/`resize` 为空操作，`status` 反映 app 是否运行、是否已贴附。

`IslandShell` 改造：选中 app tab 时不绘制内容区与输入框，岛只保留状态带 + tab 条，并把内容区的屏幕坐标交给 `WindowAttach`。切走 / 收起时 `hide()`，移除 tab 时 `restore()`。

**验证**：视觉上确认真窗口与 tab 条同宽、上沿对齐、看起来是一体的。

### 3.4 权限引导与降级

首次用到贴附时才 `AXIsProcessTrustedWithOptions` 请求。未授权时 app tab 显示「需要权限 →」占位卡，点击跳系统设置；轮询授权状态，授权后自动重试。**确认 CLI tab 完全不受影响。**

**验证**：在系统设置里撤销权限，重启 app，确认 CLI 一切正常、app tab 显示占位卡、重新授权后自动恢复。

### 3.5 最小尺寸兜底

目标窗口压不到岛宽度时（用探针 C 记录的最小尺寸），把岛加宽以匹配，而不是硬压。加宽有上限（不超过屏幕宽度减边距），超限则报「贴附失败」并提示该 app 窗口太宽。

**测试**：用假 AX 实现返回一个大于岛宽的最小尺寸，断言岛宽度被正确撑开且不超上限。

### 3.6 手动测试清单

在 `docs/manual-tests.md` 里对 ChatGPT / Claude / Cursor / 终端各执行并记录结果：贴附 → 收起 → 再展开 → 移除 tab → **验证窗口回到原始 frame** → 撤销权限后的降级 → app 被手动退出后 tab 转「未运行」。

**第 3 阶段完成标准**：四个 app 的清单全绿（或明确记录哪个 app 因 AX 限制降级成「只做调度」）。

---

## 第 4 阶段 · 打磨

按这个顺序做，每项都独立可交付：

1. ~~**错误态 UI**~~ —— **2026-08-02 做完**。非零退出在内容区显示琥珀色 ⚠︎ +
   退出码（128 以上换算成信号号）+「重新启动」；hook 通道起不来时状态带降级成
   「运行中（无详情）」，tab 条上 ＋ 前面挂一个小闪电（悬停有说明）。
   手测 §10.12–10.12c、§11.7/11.7b；单测 `ErrorStateTests`
2. **偏好设置面板** —— 悬停行为、`claude` 路径、app 预设管理、终端主题（下条）
3. **终端配色与字体主题** —— 见下方「4.3 的范围」
4. **全屏降级兜底** —— 岛隐藏期间收到 `Stop` / `Notification` 时发系统通知。
   **注意这一项不影响任务本身**：全屏时岛只是 `orderOut`，claude 照跑、hook 照收、
   tab 状态照更新，退出全屏后一切都在。缺的只是「你看不见岛的那段时间里没人通知你」
5. ~~**通知态累积的视觉**~~ —— **2026-08-02 做完**。tab 条包进
   `ScrollView(.horizontal)` + `ScrollViewReader`：溢出时两指横扫可滚，切到滚出去的
   tab 会自动带回视野，装得下时不橡皮筋。手测 §13.17–13.20
6. **终端左右二分** —— 见下方「4.6 的范围」。用户 2026-08-02：拆分要**跟 Ghostty 一致**，
   而且「现在拖大其实整体还是挺足够的」—— 不急，排在最后

> 原第 3 项「展开宽度可拖拽」已在第 1 阶段提前做掉（左右竖边 + 底边 + 两个下角），只剩「同步更新 PTY 列数」，并入第 2 阶段的终端接入。

### 4.3 的范围：终端配色与字体

用户 2026-07-31 明确划定：**只做终端这一层，不做岛体外观、不做深浅色跟随。**

- 内容区/终端的 ANSI 16 色 + 前景背景 + 光标色，配一组预置方案（Dracula、Solarized、Tokyo Night 之类），能导入 iTerm/Ghostty 的配色文件更好
- 等宽字体族与字号
- 岛体本身保持纯黑不可配：它紧挨着物理刘海，浅色岛配黑刘海视觉上是破的

依赖 SwiftTerm 已接上，所以排在第 2 阶段之后。

**2026-08-01 提前改掉的一处默认值**：内容区底色从「半透明白叠在纯黑上」（算出来 #0B0B0B）
改成不透明的 **#1E1E1E**，取自用户给的截图。原因是用户报「太黑了，看得人眼疼」——
亮字打在近乎纯黑的底上对比度顶满，长时间读发涩。输入框跟着同色（`inputFill = panelFill`），
靠描边而不是明暗区分。岛体不动，仍是纯黑。三项终端默认值（前景、光标、字体）
一并从 `TerminalPane` 提到 `IslandTheme`，好让这条主题工作有个统一的落点。

**2026-08-01 第二轮**：字号 11 → **12**。用户给了一张「就要这么大」的截图，
量出来等宽格宽 7.5pt、汉字墨高 11.5pt，岛上 11pt 时是 7.1 / 10.0，两个比值
分别指向 11.6 和 12.6，取中。代价是默认 560pt 宽的岛从约 82 列掉到约 75 列。
同一轮还把内容区卡片的**下沿接到岛的下沿**（下角半径 = 岛的半径 − 7pt 内缩），
底色提亮之后那两牙黑月牙读起来就是「终端下面多了一圈边框」。

**2026-08-01 第三轮：上一句那个改动退掉了。** 用户看完的原话是「我对月牙没有意见，
我需要看起来是整个岛，而不是终端下方跟岛外的内容没有边界，现在方向有点偏了」。
卡片顶到底之后，岛的下沿就成了终端正文的边，桌面直接从字底下开始 —— 读起来是一块
贴在屏幕上的终端，不是一座岛。现在卡片四边都留黑：左右各 7pt、下面 8pt
（`PanelCard.bottomInset`，和 `InputBar` 的下内边距对齐，这样有没有输入框、
岛的下边框都一样宽）。`bleedingBottomRadius` 连同它那条单测一起删掉了。

### 4.6 的范围：终端左右二分

用户问的是「像 Ghostty 那样的分屏」。**不做递归窗格树，只做左右二分、只对 CLI tab 生效、最多两格。** 理由：

- 岛默认 560pt ≈ 80 列，左右一分就是两个 38 列的窗格，Claude Code 的 diff 与表格在 60 列以下就散了。要真能用得先把岛拖到 900pt 以上（现在拖得动，上限约 1352pt ≈ 190 列）—— 也就是说分屏只在「用户主动把岛拉得很宽」时才成立，做递归树是给一个罕见场景付全套结构的代价
- 分屏与第 3 阶段的「第三方 app 真实窗口贴附」根本不兼容：没法把一个真实的 ChatGPT 窗口和一个终端拆成两半。所以 app tab 不参与分屏，这条限制要写进数据结构

排在第 2 阶段之后 —— 现在设计窗格树等于对着一个还不存在的终端做架构。

## 明确不在本计划内

- 守护进程模式（任务在 app 之外存活）—— 接口已在 `SessionKit` 预留，作为独立后续项目。
  **2026-08-01 补记**：Claude Code 2.1.220 自己已经带了一个（`claude daemon run` +
  `--bg-pty-host`），实机抓到过岛退出之后会话仍活着、父进程是那个 daemon。
  **2026-08-02 定案：不利用它，反过来堵上。** 用户的话是「我让不动守护进程是在你判断的
  前提下，如果是会保留，那就要改成关掉岛就要退出进程，不然跟弹框显示的信息不一致」——
  弹框上写着「退出会终止所有正在运行的 Claude Code 会话」，那句话得是真的。
  见 `SessionReaper`：退 app 按 `--settings` 扫、关 tab 按 `--session-id` 扫。
  真要做「后台跑完」是另一件事，得有 UI 说清楚哪些在后台、怎么接回来
- 全局快捷键唤起与工作目录自动推断
- 副屏显示、多岛并存
- 公证与分发
