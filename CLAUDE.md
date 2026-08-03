# NotchAgent

常驻 macOS 刘海区的灵动岛，`LSUIElement`，AppKit + SwiftUI + SwiftTerm。
两件事：在岛里跑 Claude Code 会话（真 PTY）；把第三方 AI app 的真实窗口贴到岛下面（第 3 阶段，未开工）。

现在做到哪 → [`docs/status.md`](docs/status.md)。
做什么 → `docs/superpowers/specs/`。怎么做 → `docs/superpowers/plans/`。验收 → `docs/manual-tests.md`。

## 命令

```sh
xcodebuild -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -configuration Debug build
xcodebuild test -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent -destination 'platform=macOS'
./scripts/smoke.sh
open ~/Library/Developer/Xcode/DerivedData/NotchAgent-*/Build/Products/Debug/NotchAgent.app
```

工程用文件系统同步组，**新增 `.swift` 不用改 `.pbxproj`**。测试是 Swift Testing。
签名必须是 Personal Team 的开发签名，**不能 ad-hoc / Sign to Run Locally** ——
摘要每次构建都变，辅助功能授权会反复失效。SwiftTerm 1.15 要 Metal 工具链
（`xcodebuild -downloadComponent MetalToolchain`）。

## 代码在哪

| 目录 | 装什么 |
|---|---|
| `Geometry/` | `ScreenGeometry` 量刘海与菜单栏，`NotchShape` 画那个带内凹拐角的形状 |
| `Window/` | `NotchWindow`（非激活面板、何时能成为 key）、`NotchHostingView`（命中测试收回岛轮廓、拖拽热区的光标）、`IslandWindowController`、`FocusHandoff` |
| `Island/` | `IslandState` 四态机、`IslandModel` 视图状态、`IslandMetrics` 尺寸推导、`IslandTheme`；`Views/` 是各块 UI |
| `Session/` | `CLISession` 起 `claude` 的 PTY、`SessionStore` 持久化 tab、`SessionReaper` 退出时收干净、`TerminalKeystroke` 键位翻译 |
| `Status/` | `HookBridge` 收 Claude Code 的 hook（裸 BSD socket + `nc -U`）、`StatusFeed` 拼状态带文案 |

## 硬约束

**终端交互必须和真终端一模一样。** 任何偏离都得是刻意的，并且写进
`docs/manual-tests.md` §10 末尾那张「故意不一样的地方」表。改键位、改剪贴板、
改滚动之前先去看那张表。

岛体保持纯黑不可配（它紧挨着物理刘海）。内容区 `#1E1E1E`，主题化只做终端那一层。

**光标这块坑最深**（已经第六版）。动 `ResizeHandles` / `NotchHostingView` 之前
先读 `NotchHostingView.updateTrackingAreas` 上面那段注释：AppKit 三套光标机制
默认只在 key window 生效，而岛多数时候不是 key；跟踪区的 `.mouseMoved` 在
macOS 26 上会让 WindowServer 合成 left-mouse-down，不能用。

## 干活的规矩

- **动手前先搜。** 用 grep/find 扫一遍有没有现成实现，报路径和现有逻辑，让用户决定
  是复用还是新写。别跳过这步直接开写
- **每条回归测试都要证明它真的会红。** 把修复回滚，跑，看它红，再改回来。
  上一版光标测试一直绿是因为它只读「刚进热区那一下」——坏的正是那之后
- **回滚验证脚本里绝不用 `git checkout --`**（干掉过没提交的活）。把文件内容
  `cp` 到 scratchpad 再还原。**先提交，再回滚验证**
- **别杀用户自己在跑的 NotchAgent。** 探针跑之前备份
  `~/Library/Application Support/NotchAgent/tabs.json`，跑完还原；剪贴板同理
- 截图只截岛，不截全屏
- 测试夹具从真实运行里取，别手编

## 提交

一件事一个提交，中文，说清动了什么、为什么。改了行为就同步改
`docs/manual-tests.md` 对应行，并在 `docs/status.md` 更新一句现状。
