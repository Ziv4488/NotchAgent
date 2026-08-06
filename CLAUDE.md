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
  上一版光标测试一直绿是因为它只读「刚进热区那一下」——坏的正是那之后。
  **断言里没出现被测对象的，一律当假测试**：08-06 那条
  `islandBodyIsNeverThemed` 遍历三组主题，断言却是
  `IslandTheme.edgeLine == .black`，跟循环变量毫无关系，主题全删了它也绿
- **手测行要能被自动化淘汰。** 加一行之前先问：有没有一种可信的写法能让它自动跑？
  有就去写测试，别占用人的眼睛。08-06 用户问「为什么每次最后都要做边框测试」，
  查下来那行是凑数——岛体是 `IslandShell` 里写死的 `.fill(.black)`，
  主题这条路够不着它。**真正该留给人眼的只有观感**（阴影浓淡、浅色内容区贴纯黑岛
  好不好看），那种没有可信的自动判据
- **回滚验证脚本里绝不用 `git checkout --`**（干掉过没提交的活）。把文件内容
  `cp` 到 scratchpad 再还原。**先提交，再回滚验证**
- **别杀用户自己在跑的 NotchAgent。** 探针跑之前备份
  `~/Library/Application Support/NotchAgent/tabs.json`，跑完还原；剪贴板同理
- **探针跑在 subagent 里。** 一个探针要编译、要跑、常常要跑好几轮才收敛，
  原始输出又长又不留价值。让 subagent 去跑，回来只带结论
- **探针只报结论，别把全表贴出来。** 比如 08-05 那次沿着边线逐点扫归属，
  三十行里有用的就一句「分界线正好压在岛的轮廓上」。要写数字就写**拐点**
  （在哪儿翻的、翻之前之后各是什么），扫描过程本身不用留
- **AX 探针得从一个已授权的 app 宿主里跑。** 辅助功能授权按 TCC 的
  responsible process 算：直接 exec 一个命令行工具，算的是终端（Ghostty）的账，
  而它没授权；`/private/tmp` 底下的 .app 即便手动勾了开关也不生效。可用的做法是
  签个 .app 放进 `~/Applications`（Personal Team 签名，重编不掉授权）、用 `open -n`
  起、输出重定向到文件。**`AXIsProcessTrusted()` 要在探针第一行自检** —— 没授权时
  `AXUIElementCopyAttributeValue` 是静默返回 nil 的，很容易被读成
  「这个 app 不支持该属性」而写出错误结论。现成的宿主见 `docs/status.md`
- 截图只截岛，不截全屏
- 测试夹具从真实运行里取，别手编

## 提交

一件事一个提交，中文，说清动了什么、为什么。改了行为就同步改
`docs/manual-tests.md` 对应行，并在 `docs/status.md` 更新一句现状。
