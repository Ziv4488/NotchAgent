//
//  TabStrip.swift
//  NotchAgent
//
//  tab 条。notice 与 expanded 两态共用，末尾是新建。
//

import SwiftUI
import AppKit

struct TabStrip: View {
    let model: IslandModel
    var onNewTask: () -> Void = {}

    /// 正在改名的那个 tab。同一时刻只可能有一个。
    @State private var editingTabID: UUID?
    /// 正在被拖的那个 tab，以及它此刻相对本来位置的位移。
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0
    /// 手还按着没松。**和 `draggingID` 不是一回事** —— 松手之后芯片要滑回去，
    /// 那一段 `draggingID` 还留着（不然它会当场掉到邻居底下，见 `zIndex`），
    /// 但手已经不在了，动画该开。
    @State private var handIsDown = false
    /// 已经被「换过位」消化掉的那部分位移。见 `drag(_:)`。
    @State private var dragConsumed: CGFloat = 0
    /// 上一次点在哪个 tab 上、什么时候。双击靠它自己数（见 `tapped(_:)`）。
    @State private var lastTap: (id: UUID, at: Date)?

    /// tab 条。
    ///
    /// **横向可滚动。** 岛的宽度有上限（notice 态按标题量出来、封顶在展开宽度；
    /// 展开态就是用户拖出来那么宽），tab 一多，`HStack` 会径直画出边界然后被
    /// 岛的轮廓切掉 —— 后面那几个 tab 不是变窄，是**整个消失**，连带末尾的 ＋
    /// 也点不到，一个 tab 都关不掉了。
    ///
    /// macOS 上横向滚动走的是触控板两指横扫，不是拖拽，所以和「拖着 tab 换位置」
    /// 那条 `DragGesture` 不冲突 —— 两者可以共存。
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                strip
            }
            // 装得下就别让它橡皮筋 —— 只有一两个 tab 时横着晃一下很廉价。
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(height: Layout.stripHeight)
            // 切到一个被滚出去的 tab（点通知、⌘1…9）时，得把它带回视野里，
            // 否则岛看着毫无反应：内容区换了，但 tab 条上高亮的那个在屏幕外。
            .onChange(of: model.selectedTab?.id) { _, id in
                guard let id else { return }
                withAnimation(IslandTheme.morph) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var strip: some View {
        HStack(spacing: Layout.tabGap) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab,
                        isSelected: tab.id == model.selectedTab?.id,
                        isEditing: editingTabID == tab.id,
                        backing: draggingID == tab.id ? chipBacking : nil,
                        onCommit: { newTitle in
                            model.renameTab(tab.id, to: newTitle)
                            editingTabID = nil
                        },
                        onCancel: { editingTabID = nil },
                        onClose: { model.closeTab(tab.id) })
                    // **只有一条单击手势，双击自己数。**
                    //
                    // 用户报的「每个标签之间切换反应都很慢」就出在这里：原本是
                    // `.onTapGesture(count: 2)` 叠一条 `.onTapGesture`，单击必须
                    // 先等满系统的双击间隔、确认没有第二下才轮得到它。
                    // 实机量过（合成点击 → `selectedTabID` 变化）：点下去到 tab 真的切过去
                    // **363 ms**，正是这块屏幕上的双击间隔。
                    //
                    // 换成 `.simultaneousGesture` 也没用 —— 又量了一次，还是 363 ms。
                    // 只要 SwiftUI 里存在一条 count: 2 的手势，单击就得等。
                    // 所以干脆不要那条手势：单击当场生效，第二下来了再按间隔
                    // 自己判成双击。改名照旧，切 tab 不再等任何东西。
                    .onTapGesture { tapped(tab) }
                    .offset(x: draggingID == tab.id ? dragOffset : 0)
                    // 被拖的那个要压在别人上面，否则挪过去的一路上会被邻居切掉一半。
                    .zIndex(draggingID == tab.id ? 1 : 0)
                    // **手底下那个不许有动画。** 换位时邻居要滑，是靠 `moveTab`
                    // 外面那圈 `withAnimation`；可那一下同时也把被拖的芯片挪了
                    // 一整格（它在 HStack 里换了槽位），那个位移要是也插值，
                    // 芯片就会从手底下滑走、再慢慢追回来 —— 正是「不跟手」。
                    // 位移补偿（`dragConsumed`）是瞬时的，槽位也必须瞬时。
                    .transaction { txn in
                        if handIsDown, draggingID == tab.id { txn.animation = nil }
                    }
                    .gesture(drag(tab))
                    // 给 ScrollViewReader 认的。用 tab 自己的 id，
                    // 和 `selectedTabID` 是同一个东西，滚过去不用再翻译一次。
                    .id(tab.id)
            }
            if model.hookChannelDegraded { degradedHint }
            Button(action: onNewTask) {
                Text("＋")
                    .font(IslandTheme.tabFont)
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.horizontal, Layout.plusHPadding)
                    .padding(.vertical, Layout.chipVPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Layout.stripHPadding)
        .frame(height: Layout.stripHeight)
    }

    /// hook 通道没连上时挂在 ＋ 前面的那一点提示（spec 6.4 的降级）。
    ///
    /// **要低调。** 终端本身完全正常，能干的活一件不少，只是岛看不到进度了；
    /// 拿一条横幅去挡住半个岛是过度反应。一个琥珀色小图标 + 悬停说明就够，
    /// 它解释的是「为什么状态带上只有项目名」这一个疑问。
    private var degradedHint: some View {
        Image(systemName: "bolt.horizontal.circle")
            .font(.system(size: 11))
            .foregroundStyle(IslandTheme.amber.opacity(0.75))
            .padding(.horizontal, 2)
            .help("状态通道没连上：终端照常用，但岛读不到进度，收起态只显示「运行中（无详情）」。")
    }

    /// 点了一下某个 tab。
    ///
    /// 第一下**立刻**切过去；紧接着的第二下（同一个 tab、在系统的双击间隔内）
    /// 才算双击 —— 那时切换已经发生过了，双击只要再进改名就行。
    /// 这个顺序和「双击 = 单击 + 单击」在别处的行为是一致的。
    private func tapped(_ tab: IslandTab) {
        let now = Date()
        let isDouble = lastTap.map {
            $0.id == tab.id && now.timeIntervalSince($0.at) <= NSEvent.doubleClickInterval
        } ?? false
        lastTap = (tab.id, now)

        model.selectTab(tab.id)
        // 收起态的 tab 条宽度是按标题量出来的（measuredWidth），
        // 在那儿改名会让整块岛跟着抽。只在展开态允许。
        if isDouble, model.state == .expanded {
            editingTabID = tab.id
        } else if editingTabID != tab.id {
            editingTabID = nil
        }
    }

    /// 拖着 tab 换位置。
    ///
    /// 拖的时候只有**被拖的那个**跟着鼠标走；一旦越过邻居的一半，就当场
    /// 换位（`moveTab`），同时把那一格的宽度记进 `dragConsumed` ——
    /// 位移要减掉它，否则芯片已经挪到新位置了、偏移量却还从原点算，
    /// 手一停它就飞出去一格。
    ///
    /// `minimumDistance` 不能是 0：那样单纯的点击也会被算成一次拖拽，
    /// 切 tab 就点不动了。
    private func drag(_ tab: IslandTab) -> some Gesture {
        // **坐标系必须是 `.global`。**
        //
        // 默认那个是**芯片自己的**局部坐标系 —— 而换位之后芯片整个挪了一格，
        // 局部原点跟着挪，于是 `translation` 当场跳了一整格：本来是 +0.7 格，
        // 一换位变成 -0.3 格，再减掉我们记的那一格补偿就成了 -1.3 格，
        // 反向条件立刻成立 → 换回去 → translation 又跳回来 → 再换过去。
        // 探针实测：手停在换位线附近抖 ±3pt，六下里换位发生了 **5 次**。
        // 这就是用户报的「拖动的时候会抽动」。
        //
        // 全局坐标系不随视图移动，位移才是手真的走了多远。
        DragGesture(minimumDistance: Layout.dragThreshold, coordinateSpace: .global)
            .onChanged { value in
                draggingID = tab.id
                handIsDown = true
                var offset = value.translation.width - dragConsumed
                guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }

                if offset > 0, index + 1 < model.tabs.count {
                    let step = Self.chipWidth(for: model.tabs[index + 1]) + Layout.tabGap
                    if offset > step * Layout.swapThreshold {
                        // **先把位移落定，再换位。** 换位那句在 `withAnimation` 里，
                        // 写在它后面的状态改动会被卷进同一个事务、跟着一起插值。
                        dragOffset = offset - step
                        dragConsumed += step
                        withAnimation(IslandTheme.tabSlide) { model.moveTab(from: index, to: index + 1) }
                        return
                    }
                } else if offset < 0, index > 0 {
                    let step = Self.chipWidth(for: model.tabs[index - 1]) + Layout.tabGap
                    if -offset > step * Layout.swapThreshold {
                        dragOffset = offset + step
                        dragConsumed -= step
                        withAnimation(IslandTheme.tabSlide) { model.moveTab(from: index, to: index - 1) }
                        return
                    }
                }
                dragOffset = offset
            }
            .onEnded { _ in
                // 手先松开（这一下把上面那条 `.transaction` 的封印解掉），
                // 芯片再滑回槽位里。`draggingID` 留到动画放完才清 ——
                // 提前清掉它 `zIndex` 当场掉到 0，归位的一路上会被邻居压住。
                handIsDown = false
                dragConsumed = 0
                withAnimation(IslandTheme.tabSlide) {
                    dragOffset = 0
                } completion: {
                    draggingID = nil
                }
                // 顺序是用户排的，重启后得还是这个顺序。
                model.persistTabs()
            }
    }

    /// 拖动中的芯片垫在底下的那层不透明底色。
    ///
    /// 芯片本来只有选中时才有背景，而且是**半透明**的白 11% —— 于是拖过邻居
    /// 时两边的字直接叠在一起（用户 08-04 报的「tab 之间的内容有穿插」）。
    /// 没选中的那个更糟：整块全透。
    ///
    /// 垫的这层要和芯片**底下那块岛体一模一样**，不然芯片会显出一块深色补丁：
    /// 岛体是纯黑，但收起态悬停时整块岛叠着一层白 5%（`hoverTint`），
    /// 叠出来是 `white: 0.05`。展开态没有那层提亮。
    private var chipBacking: Color {
        Color(white: model.isHovering && model.state != .expanded ? 0.05 : 0)
    }
}

/// 不是 `private`：`TabStripPixelTests` 要单独渲一个拖动中的芯片，
/// 量它到底透不透光。
struct TabChip: View {
    let tab: IslandTab
    let isSelected: Bool
    var isEditing = false
    /// 拖动中垫在底下的不透明底色；不在拖动中就是 nil（见 `TabStrip.chipBacking`）。
    var backing: Color?
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            icon
            if isEditing {
                nameField
            } else {
                Text(tab.title)
                    .font(IslandTheme.tabFont)
                    .foregroundStyle(isSelected ? IslandTheme.bright : Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            closeButton
        }
        .padding(.horizontal, TabStrip.Layout.chipHPadding)
        .padding(.vertical, TabStrip.Layout.chipVPadding)
        .background {
            ZStack {
                // 拖动中先垫一层不透明的。颜色和芯片底下那块岛体相同，
                // 所以看不出多了一层，但邻居的字透不过来了。
                if let backing {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(backing)
                }
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(IslandTheme.tabActiveFill)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.white.opacity(0.13)).frame(height: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onChange(of: isEditing, initial: true) { _, editing in
            guard editing else { return }
            draft = tab.title
            fieldFocused = true
        }
    }

    /// 关掉这个会话。
    ///
    /// **位置永远留着，只是平时不画**（`opacity`，不是 `if`）。收起态的岛宽
    /// 是按 tab 条量出来的（`TabStrip.measuredWidth`），让这个按钮时有时无，
    /// 鼠标一扫过去整块岛就跟着变宽 —— 那比多留 12pt 难受得多。
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: TabStrip.Layout.closeSize, height: TabStrip.Layout.closeSize)
                .background {
                    Circle().fill(Color.white.opacity(hovered ? 0.16 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovered || isSelected ? 1 : 0)
        .help("关闭这个会话")
    }

    /// 原地改名。回车确认，Esc 放弃。
    ///
    /// 宽度自己量：TextField 在 HStack 里默认会把剩下的地方全占了，
    /// tab 条会被一个输入框撑满。按草稿实时量宽度，输入时芯片跟着长。
    private var nameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(IslandTheme.tabFont)
            .foregroundStyle(IslandTheme.bright)
            .focused($fieldFocused)
            .frame(width: TabStrip.fieldWidth(for: draft))
            .onSubmit { onCommit(draft) }
            // Esc 现在一路放行给终端（见 IslandWindowController.action），
            // 但改名时 first responder 是这个输入框，轮不到终端 —— 正好当「放弃」。
            .onExitCommand(perform: onCancel)
    }

    /// 图标始终在，状态挂角标 —— 用状态点顶掉图标会让 tab 失去身份，
    /// 而 tab 条最要紧的就是「哪个是哪个」。
    private var icon: some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(tab.status == .ended ? tab.accent.opacity(0.35) : tab.accent)
            .frame(width: TabStrip.Layout.iconSize, height: TabStrip.Layout.iconSize)
            .overlay {
                Image(systemName: tab.kind == .cli ? "terminal" : "app")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder
    private var badge: some View {
        switch tab.status {
        case .done where tab.unread:
            // 完成且未读：绿色对勾（spec 3.1）。
            dot(IslandTheme.green) {
                Image(systemName: "checkmark")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.black)
            }
        case .waiting:
            // 停下来等你回话。这个必须比「在跑」更抓眼 —— 不理它就一直卡着。
            dot(IslandTheme.blue) {
                Image(systemName: "questionmark")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.white)
            }
        case .running:
            dot(IslandTheme.amber) { EmptyView() }
        default:
            EmptyView()
        }
    }

    private func dot<Content: View>(_ color: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(content())
            .overlay(Circle().stroke(.black, lineWidth: 1.5))
            .offset(x: 3, y: 3)
    }
}

extension TabStrip {
    enum Layout {
        static let stripHeight: CGFloat = 34
        static let stripHPadding: CGFloat = 7
        static let tabGap: CGFloat = 3
        static let chipHPadding: CGFloat = 9
        static let chipVPadding: CGFloat = 4
        static let plusHPadding: CGFloat = 7
        static let iconSize: CGFloat = 14
        static let minFieldWidth: CGFloat = 44
        static let closeSize: CGFloat = 12
        /// hook 降级提示那个小图标连内边距占多宽（见 `degradedHint`）。
        static let degradedHintWidth: CGFloat = 15
        /// 手指头挪多远才算是在拖 tab 而不是在点它。
        static let dragThreshold: CGFloat = 5
        /// 越过邻居多少才换位，按邻居宽度的比例算。
        ///
        /// **不能是 0.5。** 换位之后芯片的位置前进了一整格，位移要减掉同样一格，
        /// 于是它当场落在「离新的左邻居正好半格」的地方 —— 反向条件刚好也在
        /// 半格上，手稍微抖一下就来回换位。这就是用户报的「拖动的时候会抽动」。
        /// 0.6 留出 0.2 格的余量，往回也得真的走过去才换。
        static let swapThreshold: CGFloat = 0.6
    }

    /// 改名输入框该多宽：按当前草稿量，另留一点余量给光标。
    ///
    /// 下限不是为了好看 —— 名字删空时输入框会缩成零宽，光标消失、
    /// 谁都不知道自己还在编辑状态，只能瞎按。
    static func fieldWidth(for draft: String) -> CGFloat {
        let measured = (draft as NSString).size(withAttributes: [.font: titleFont]).width
        return max(Layout.minFieldWidth, ceil(measured) + 6)
    }

    /// tab 标题用的字体。量宽度和渲染必须是同一个，否则量出来的宽度不作数。
    ///
    /// **别把这个变量叫 `font`。** `TabStrip` 是个 `View`，`View` 带一个
    /// `font(_:)` 修饰器；在静态方法里写 `[.font: font]`，`font` 会解析成
    /// 那个**没被调用的方法本身**。字典值类型是 `Any`，编译器一声不吭地收下，
    /// 到运行时 AppKit 拿着一个 `__SwiftValue` 去问它 `pointSize` ——
    /// app 在第一帧布局就 crash。这个坑踩过一次。
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// tab 条渲染出来需要多宽 —— notice 态靠这个撑开（spec 3.1）。
    ///
    /// 用 AppKit 量文字宽度，比让 SwiftUI 先渲染再回读尺寸简单，
    /// 也避免了「量完再改宽度」这一帧的布局抖动。
    /// 一个芯片渲染出来有多宽。拖拽换位靠它算「越过邻居没有」。
    ///
    /// 关闭按钮**始终**算进来 —— 它平时透明但占着位置（见 `closeButton`）。
    static func chipWidth(for tab: IslandTab) -> CGFloat {
        let textWidth = (tab.title as NSString).size(withAttributes: [.font: titleFont]).width
        return Layout.chipHPadding * 2 + Layout.iconSize + 5 + ceil(textWidth)
            + 5 + Layout.closeSize
    }

    static func measuredWidth(for tabs: [IslandTab], hookDegraded: Bool = false) -> CGFloat {
        var width = Layout.stripHPadding * 2

        for tab in tabs {
            width += chipWidth(for: tab)
            width += Layout.tabGap
        }

        // 降级提示那个小图标也占地方 —— 不算进来的话 notice 态的岛会窄一截，
        // 末尾的 ＋ 正好被切掉半个。
        if hookDegraded { width += Layout.degradedHintWidth + Layout.tabGap }

        // 末尾的 ＋
        let plusWidth = ("＋" as NSString).size(withAttributes: [.font: titleFont]).width
        width += Layout.plusHPadding * 2 + ceil(plusWidth)
        return width
    }
}
