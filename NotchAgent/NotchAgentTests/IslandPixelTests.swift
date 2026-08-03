//
//  IslandPixelTests.swift
//  NotchAgentTests
//
//  岛画出来是什么样 —— 把「盯着看」的那些行做成断言。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

/// **第二批「看得见」的测试**，接着 `TerminalSelectionPixelTests` 那条路子往下走。
///
/// 手测清单里最难交代的一类是「盯着看」：黑边多宽、两条弧平不平行、
/// 岛外有没有一圈黑雾、文字压没压到刘海底下。这些都不是状态，是**画面** ——
/// 所以只能由画面来回答。做法是把视图交给 `ImageRenderer` 渲成位图，
/// 铺在一块**故意选得很扎眼**的底色上（品红），然后按颜色把每个像素归类：
/// 品红 = 岛外面、纯黑 = 岛体、#1E1E1E = 卡片。归完类，「左右各让出 7pt」
/// 就是一句可以写下来的断言。
///
/// **和 `ThemeTests` 那两条不重复。** 那边断言的是常量之间的关系
/// （`PanelCard.cardRadius == bottomCornerRadius - inset`），这边断言的是
/// 那些常量**真的被用上了**：padding 挂在了对的那一层、圆角画出来真的同心。
/// 常量对而 padding 忘了加，那边照样绿。
@Suite("岛的画面")
@MainActor
struct IslandPixelTests {

    // MARK: - 位图与取色

    /// 岛外面那片底色。**故意选品红**：岛体是纯黑、卡片是 #1E1E1E，
    /// 三者两两之间隔得越远，分类就越不容易被抗锯齿糊掉。
    private static let backdrop = Color(red: 1, green: 0, blue: 1)

    /// 一张渲染好的位图，外加「这个像素是什么」的判定。
    private struct Raster {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        /// y 从 0 开始是**画面顶端**（位图的行序），和视图坐标一致。
        func color(_ x: Int, _ y: Int) -> NSColor {
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        }

        func gray(_ x: Int, _ y: Int) -> CGFloat {
            let c = color(x, y)
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }

        /// 岛外面：品红。
        func isBackdrop(_ x: Int, _ y: Int) -> Bool {
            let c = color(x, y)
            return c.redComponent > 0.85 && c.greenComponent < 0.15 && c.blueComponent > 0.85
        }

        /// 卡片 / 输入框的底：#1E1E1E 那一档灰。
        /// 上下限放得比较宽，因为上面还压着一层 0.5pt 的白描边（`panelStroke`）。
        func isCard(_ x: Int, _ y: Int) -> Bool {
            let c = color(x, y)
            let neutral = abs(c.redComponent - c.greenComponent) < 0.06
                && abs(c.greenComponent - c.blueComponent) < 0.06
            return neutral && gray(x, y) > 0.055 && gray(x, y) < 0.40
        }

        /// 从左往右第一个不是底色的像素 —— 也就是岛的左边界。
        func firstNonBackdrop(row y: Int) -> Int? {
            (0..<width).first { !isBackdrop($0, y) }
        }

        func firstCard(row y: Int) -> Int? {
            (0..<width).first { isCard($0, y) }
        }

        func lastCard(row y: Int) -> Int? {
            (0..<width).last { isCard($0, y) }
        }
    }

    /// 把一个 SwiftUI 视图渲成位图。
    ///
    /// **用 `ImageRenderer` 而不是 `cacheDisplay`。** 后者是 AppKit 的路子，
    /// SwiftUI 的内容走的是图层合成，离屏 `cacheDisplay` 出来可能是空白 ——
    /// 量一张白图会得出「什么都对」的假绿。`ImageRenderer` 是 SwiftUI 自己的
    /// 光栅化入口，确定性也更好（`scale = 1`，一个点就是一个像素，
    /// 断言里的 7 和 8 就是 pt）。
    private func raster(_ view: some View, size: CGSize,
                        backdrop: Color = IslandPixelTests.backdrop) throws -> Raster {
        let root = ZStack(alignment: .top) {
            backdrop
            view
        }
        .frame(width: size.width, height: size.height)
        // 拖拽手柄里那层登记光标的 AppKit 视图要关掉：`ImageRenderer` 画不了
        // AppKit 内容，会拿一块不透明的黄块（`1.00/0.80/0.00`）顶上去，
        // 把它底下要量的东西盖住 —— 卡片的下角正好在角手柄底下。
        .environment(\.installsCursorRects, false)

        let renderer = ImageRenderer(content: root)
        renderer.scale = 1
        let cg = try #require(renderer.cgImage, "渲不出图，后面所有断言都没有意义")

        // **不能直接 `NSBitmapImageRep(cgImage:)`。** `ImageRenderer` 交出来的
        // 图带的是一个扩展 / HDR 色彩空间，`colorAt` 在那上面读出来的分量是错的
        // ——实测一块纯品红读成了 `(1, 0.83, 0)`，按颜色分类的整套判定当场作废。
        // 自己开一张老老实实的 8 位 deviceRGB 位图，把图画进去再量。
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        NSGraphicsContext.restoreGraphicsState()
        return Raster(rep: rep)
    }

    private func detachedModel() -> IslandModel {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "会话")
        model.apply(.finished(0), to: model.tabs[0].id)
        model.previewState(.expanded)
        return model
    }

    /// 画布要比岛大一圈 —— 岛外面那一圈也是要量的东西。
    /// 太小的话岛会被画布切掉，「下沿在哪儿」直接量成画布底边。
    private func canvas(around model: IslandModel) -> CGSize {
        CGSize(width: model.size.width + 340, height: model.size.height + 170)
    }

    /// 在岛的下半段里挑一条**干净的**竖线来量。
    ///
    /// 不能用正中间：底边中央摞着拖拽手柄那条白色短横条（`Color.white.opacity(0.16)`，
    /// 灰度正好落在卡片那一档里），从中列往下扫，最后一个「卡片色」像素会是它，
    /// 量出来的下边框成了 1pt。往边上挪 150pt 就避开了。
    private func cleanColumn(_ image: Raster) -> Int { image.width / 2 - 150 }

    /// 定稿要求的黑边宽度，**写死**。
    ///
    /// 这两个数不引用 `PanelCard.inset` / `.bottomInset`：那样等号两边会一起动，
    /// 把常量改成 0 测试照样绿（第一版就是这么写的，revert 验证时当场露馅）。
    /// 常量之间的关系归 `ThemeTests` 管，这里管的是**画出来是几个像素**。
    private static let expectedSideMargin: CGFloat = 7
    private static let expectedBottomMargin: CGFloat = 8

    // MARK: - §10.10 / 10.10b：卡片四边的黑边

    /// 内容区那张卡：左右各让出 `PanelCard.inset`，下面让出 `bottomInset`。
    ///
    /// 用户的原话是「我需要看起来是整个岛，而不是终端下方跟岛外的内容没有边界」。
    /// 卡片一旦顶到岛的下沿，岛的下边框就成了正文的边，桌面从字底下开始。
    ///
    /// 把 `ContentArea` 里任何一处 `.padding` 拿掉，这条立刻红。
    @Test("内容区的卡片：左右各 7pt、下面 8pt 的黑边")
    func contentCardLeavesMargins() throws {
        let model = detachedModel()
        let size = CGSize(width: 560, height: 300)
        let image = try raster(ContentArea(model: model, tab: model.tabs[0],
                                           bottomInset: PanelCard.bottomInset),
                               size: size)

        // 卡片竖直方向的正中间，横着扫一行。
        let midRow = image.height / 2
        let left = try #require(image.firstCard(row: midRow), "这一行上根本没有卡片")
        let right = try #require(image.lastCard(row: midRow))
        #expect(abs(CGFloat(left) - Self.expectedSideMargin) <= 1, "左边黑边是 \(left)pt，该是 7")
        #expect(abs(CGFloat(image.width - 1 - right) - Self.expectedSideMargin) <= 1,
                "右边黑边是 \(image.width - 1 - right)pt，该是 7")

        // 卡片正中间，竖着往下扫到底。
        let midCol = image.width / 2
        let bottom = try #require((0..<image.height).last { image.isCard(midCol, $0) })
        #expect(abs(CGFloat(image.height - 1 - bottom) - Self.expectedBottomMargin) <= 1,
                "下面黑边是 \(image.height - 1 - bottom)pt，该是 8")
    }

    /// §10.10b：新建表单和内容区共用同一张 `PanelCard`，黑边必须一样宽。
    /// 这张表单是另一条渲染路径 —— 一样会有人只给其中一条加 padding。
    @Test("新建表单的卡片：黑边和内容区一样宽")
    func newTaskFormLeavesTheSameMargins() throws {
        let size = CGSize(width: 560, height: 300)
        let projects = (1...3).map {
            ProjectDirectory(path: "/tmp/项目-\($0)", lastUsed: .distantPast, hasSessions: true)
        }
        let image = try raster(NewTaskForm(projects: projects,
                                           bottomInset: PanelCard.bottomInset,
                                           onSubmit: { _, _ in }, onCancel: {})
                                   .frame(width: size.width, height: size.height),
                               size: size)

        let midRow = image.height / 2
        let left = try #require(image.firstCard(row: midRow))
        let right = try #require(image.lastCard(row: midRow))
        #expect(abs(CGFloat(left) - Self.expectedSideMargin) <= 1, "左边黑边是 \(left)pt")
        #expect(abs(CGFloat(image.width - 1 - right) - Self.expectedSideMargin) <= 1)

        let midCol = image.width / 2
        let bottom = try #require((0..<image.height).last { image.isCard(midCol, $0) })
        #expect(abs(CGFloat(image.height - 1 - bottom) - Self.expectedBottomMargin) <= 1)
    }

    // MARK: - §10.10c / 10.10d：岛下沿那一圈

    /// §10.10c：会话结束、输入框回来之后，岛的下边框**一样宽**。
    ///
    /// 会话活着时那 8pt 由内容区留（下面没有输入框），结束后由输入框自己的
    /// `.padding(.bottom, 8)` 留。两条路各留各的，谁改了谁都不会惊动对方 ——
    /// 所以要有一条钉着「两边都是 8」。
    @Test("岛的下边框：输入框回来之后还是 8pt")
    func islandKeepsItsBottomEdgeWithTheInputBar() throws {
        let model = detachedModel()
        let image = try raster(IslandShell(model: model), size: canvas(around: model))

        let column = cleanColumn(image)
        let islandBottom = try #require((0..<image.height).last { !image.isBackdrop(column, $0) },
                                        "整张图都是底色 —— 岛没画出来")
        let fillBottom = try #require((0..<image.height).last { image.isCard(column, $0) })
        #expect(abs(CGFloat(islandBottom - fillBottom) - Self.expectedBottomMargin) <= 1,
                "岛的下边框量出来是 \(islandBottom - fillBottom)pt，该是 8")
    }

    /// §10.10d：**两条弧处处平行**。
    ///
    /// 卡片半径写死过 10pt，比同心该有的圆得多 —— 直边上黑边是 7，转到角上
    /// 就宽出一截，两条弧一眼看得出不是一套的（用户报的「岛的圆角需与终端的
    /// 圆角保持一致」）。这里逐行量岛的左边界到卡片左边界的距离：同心的话
    /// 这个距离从直边一路走到角上都不怎么变。
    ///
    /// 把 `PanelCard.cardRadius` 改回写死的 10，这条立刻红。
    @Test("岛的下角和卡片的下角同心：黑边宽度一路不变")
    func bottomCornersAreConcentric() throws {
        let model = detachedModel()
        let image = try raster(IslandShell(model: model), size: canvas(around: model))

        let column = cleanColumn(image)
        let islandBottom = try #require((0..<image.height).last { !image.isBackdrop(column, $0) })
        let fillBottom = try #require((0..<image.height).last { image.isCard(column, $0) })

        // 只看两条弧**同时存在**的那几行：卡片的弧从它自己的下沿往上一个
        // `cardRadius`，岛的弧从岛的下沿往上一个 `bottomCornerRadius`。
        var gaps: [Int] = []
        for y in (fillBottom - Int(PanelCard.cardRadius))...fillBottom {
            guard y >= 0,
                  let islandLeft = image.firstNonBackdrop(row: y),
                  let cardLeft = image.firstCard(row: y) else { continue }
            gaps.append(cardLeft - islandLeft)
        }

        #expect(gaps.count > Int(PanelCard.cardRadius),
                "下角这一段几乎没量到东西，样本只有 \(gaps.count) 行")
        let low = try #require(gaps.min())
        let high = try #require(gaps.max())
        // 直边上就是 `inset`（7）。往角上走会略微张开一点点 —— 卡片下面缩的是 8、
        // 左右缩的是 7，两条弧的圆心差着 1pt，不可能严丝合缝。写死 10pt 那一版
        // 在同一段里量出来是 13pt 上下，所以 11 这条线两边分得很开。
        #expect(low >= Int(Self.expectedSideMargin) - 1, "转角处黑边最窄 \(low)pt")
        #expect(high <= 11, "转角处黑边最宽 \(high)pt —— 两条弧不是一套的")
    }

    // MARK: - §1.1 / 1.7：岛外面什么都没有

    /// 岛的边缘和桌面之间是**硬边界**。
    ///
    /// 曾经有一圈 12pt 的投影：落在这块透明画布上是洗不掉的黑雾，
    /// 把窗口挪到岛正后方就能看见一圈渐变暗环（§1.7）。这条量的是
    /// 岛外面 3–20pt 那一圈**一个像素都没被动过**。
    ///
    /// **边界从 `model.size` 算，不从像素找。** 第一版是「从底下往上找第一个
    /// 不是底色的像素」当作岛的下沿 —— 挂上投影之后那个位置跟着投影一起下移，
    /// 检查的带子也跟着走，于是测试照样绿。要查的东西自己会移动检查的地方，
    /// 这种度量一律不能用。岛的尺寸是已知的，直接拿。
    @Test("岛外面没有描边，也没有一圈黑雾", arguments: [IslandState.idle, .running, .expanded])
    func nothingBleedsOutsideTheIsland(state: IslandState) throws {
        let model = IslandModel.previewModel(state: state)
        let size = canvas(around: model)
        let image = try raster(IslandShell(model: model), size: size)

        // 岛贴着画布顶边、水平居中；两侧的内凹圆弧画在主体之外。
        let islandBottom = Int(model.size.height) - 1
        let bodyLeft = Int((size.width - model.size.width) / 2)
        let outerLeft = bodyLeft - Int(model.cornerRadii.inverted)

        // 下沿往下 3pt 起、20pt 止的一整条带子。
        var dirty = 0
        for y in (islandBottom + 3)..<min(image.height, islandBottom + 20) {
            for x in 0..<image.width where !image.isBackdrop(x, y) { dirty += 1 }
        }
        #expect(dirty == 0, "岛下沿外面有 \(dirty) 个像素不是底色 —— 投影又回来了")

        // 侧边同理：取岛竖直方向的中段，往左看一条。
        let probeRow = islandBottom / 2
        var sideDirty = 0
        for x in max(0, outerLeft - 20)..<max(0, outerLeft) where !image.isBackdrop(x, probeRow) {
            sideDirty += 1
        }
        #expect(sideDirty == 0, "岛左边有 \(sideDirty) 个像素不是底色")
    }

    // MARK: - §6.3：文字不许压到刘海底下

    /// 左右两侧的字**都不能伸进中间那段刘海**。
    ///
    /// `StatusBand` 已经改成两侧定宽（`Spacer(minLength:)` 只保证下限，
    /// 一侧内容长了 HStack 会把中缝压掉）。那是结构上的保证，这条是画面上的
    /// 复核：中间那一整块里，一个亮像素都不该有。
    ///
    /// 底色换成纯黑 —— 岛体本来就是黑的，这样「亮起来的」就只剩字。
    @Test("状态带的字不会伸进刘海底下")
    func statusBandTextStaysOutOfTheNotch() throws {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        // 故意给一个长到必须截断的标题：压不压得住只有在这种时候才看得出来。
        model.debugStartSession(named: "一个长得离谱的会话名字用来把状态带撑爆掉")
        model.debugStartSession(named: "另一个会话")

        let width: CGFloat = 345
        let gap: CGFloat = 200
        let height: CGFloat = 32
        let image = try raster(StatusBand(model: model, totalWidth: width,
                                          notchGap: gap, height: height),
                               size: CGSize(width: width, height: height),
                               backdrop: .black)

        // 中间那段的像素范围，两边各让 1pt 给抗锯齿。
        let gapLeft = Int((width - gap) / 2) + 1
        let gapRight = Int((width + gap) / 2) - 1
        var lit = 0
        for y in 0..<image.height {
            for x in gapLeft..<gapRight where image.gray(x, y) > 0.25 { lit += 1 }
        }
        #expect(lit == 0, "刘海那一段里有 \(lit) 个亮像素 —— 有字跑进去了")

        // 反过来确认这张图**确实有字**，否则上面那条是靠「什么都没画」蒙过去的。
        var litOutside = 0
        for y in 0..<image.height {
            for x in 0..<gapLeft where image.gray(x, y) > 0.25 { litOutside += 1 }
        }
        #expect(litOutside > 50, "左半边根本没画出字，这条测试等于没测")
    }

    // MARK: - §8.1：下角不该有拖拽标记

    /// 展开态的边缘上**只有底边中央一条短横条**。
    ///
    /// 两个下角是圆角、贴着桌面，在那儿画直角线读起来像「岛外面还套了个框」。
    /// 手柄本身照常能拖（那是命中区，不画东西），这条量的只是「画了什么」。
    @Test("拖拽手柄只在底边中央露一条，两个下角什么都没有")
    func onlyTheBottomCenterHandleIsVisible() throws {
        let model = IslandModel.previewModel(state: .expanded)
        let islandSize = model.size
        let image = try raster(ResizeHandles(model: model, islandSize: islandSize,
                                             topInset: model.geometry.menuBarHeight),
                               size: islandSize,
                               backdrop: .black)

        func lit(x: Range<Int>, y: Range<Int>) -> Int {
            var n = 0
            for yy in y where yy >= 0 && yy < image.height {
                for xx in x where xx >= 0 && xx < image.width && image.gray(xx, yy) > 0.06 { n += 1 }
            }
            return n
        }

        let bottom = image.height - 8..<image.height
        let center = image.width / 2 - 20..<image.width / 2 + 20
        #expect(lit(x: center, y: bottom) > 0, "底边中央那条横条没画出来")
        #expect(lit(x: 0..<50, y: bottom) == 0, "左下角画了东西")
        #expect(lit(x: image.width - 50..<image.width, y: bottom) == 0, "右下角画了东西")
    }

    // MARK: - §14.13b：浮层刚出来时一项都不亮

    /// 鼠标还没进去，**没有哪一项该带着底色**。
    ///
    /// 曾经跟着终端光标高亮一项（默认就是第 1 项）。浮层上的选项是按钮，
    /// 一进来就有一项亮着读起来是「已经选好了」，而其实什么都还没发生。
    ///
    /// 量法：在选项行的左侧空白处竖着取一列（在圆角矩形里面、在文字左边），
    /// 整列应该是**一个平的底色**。有一项亮着的话，那一段会整体抬高一档。
    @Test("浮层刚出来时，没有哪一项自带底色")
    func noOptionIsPrelitInTheMenuPanel() throws {
        let menu = TerminalMenu(question: "要我改这个文件吗？",
                                options: [.init(number: 1, title: "Yes", detail: nil),
                                          .init(number: 2, title: "Yes, and don't ask again", detail: nil),
                                          .init(number: 3, title: "No", detail: nil)],
                                selected: 1)
        let width = MenuPanel.Layout.width
        let image = try raster(MenuPanel(menu: menu, width: width, onChoose: { _ in }),
                               size: CGSize(width: width, height: 200),
                               backdrop: .black)

        // 选项行的底色矩形从 x=6 起（`.padding(.horizontal, 6)`），文字从 12 起。
        // 取 9：在矩形里面、圆角之外、文字左边。
        let column = 9
        let grays = (0..<image.height).map { image.gray(column, $0) }
        let base = grays.sorted()[grays.count / 2]     // 中位数 = 面板底色
        // 高出底色一档的像素 —— 高亮是 `hoverTint`（白 0.05），一整行会有二十几 pt 高。
        let brighter = grays.filter { $0 > base + 0.02 }.count
        #expect(brighter < 6, "有 \(brighter) 行比底色亮 —— 某一项自带底色了")
    }


    // MARK: - §14.12：浮层和岛接成一整块

    /// 浮层是从岛上**长下来**的，不是另外一张卡片。
    ///
    /// 中间留一道缝会露出桌面，读起来就成了两样东西（用户报过一次
    /// 「选项跟岛隔开了」）。这条从岛顶一路扫到浮层底：中间**一个底色像素都不许有**。
    ///
    /// 上面那两个角是方的、也不往上盖 —— 盖上去会把 tab 的下沿削平（§14.12b），
    /// 那件事由 `MenuWiringTests`「挂着浮层时，岛的底部圆角收掉」管着。
    @Test("浮层和岛之间没有缝")
    func menuPanelJoinsTheIslandWithoutASeam() throws {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "会话")
        model.apply(TerminalMenu(question: "要我改这个文件吗？",
                                 options: [.init(number: 1, title: "Yes", detail: nil),
                                           .init(number: 2, title: "No", detail: nil)],
                                 selected: 0),
                    to: model.tabs[0].id)
        let menu = try #require(model.pendingMenu, "浮层没挂上，这条测试等于没测")
        #expect(menu.options.count == 2)

        let size = CGSize(width: model.size.width + 340, height: 460)
        let image = try raster(IslandShell(model: model), size: size)

        // 挑一条同时穿过岛和浮层的竖线。浮层比岛窄（320 对 345+），所以往里挪一点。
        let column = image.width / 2 - 80
        let bottom = try #require((0..<image.height).last { !image.isBackdrop(column, $0) },
                                  "整条线都是底色 —— 岛和浮层都没画出来")
        #expect(bottom > Int(model.size.height) + 40, "浮层根本没画出来，只量到了岛")

        let seam = (0...bottom).filter { image.isBackdrop(column, $0) }
        #expect(seam.isEmpty, "岛和浮层之间有 \(seam.count)pt 的缝，缝里是桌面：\(seam.prefix(8))")
    }

    // MARK: - §5.0b：「选择其他目录…」钉在列表外面

    /// 项目再多，「选择其他目录…」也不跟着滚走。
    ///
    /// 它原来是滚动列表里的最后一行，项目一多就滚出视野 —— 于是
    /// `~/.claude/projects` 里没有的目录在界面上根本找不到入口
    /// （用户报的「开不了没会话的目录，只能 resume」）。
    ///
    /// **不能用像素比对。** 试过「3 个项目 / 40 个项目各画一遍，比下面那一截」：
    /// 两种排法下那一截都是一样的（列表把视口填满与否的差别落在更上面），
    /// 把它挪回列表里测试照样绿。直接量结构才行：滚动视图**底下留了多少地方**。
    /// 钉住的时候那儿摆着「选择其他目录…」+ 分隔线 + 指令框；
    /// 挪回列表里就只剩后两样，一下子少掉一整行的高度。
    @Test("「选择其他目录…」在滚动列表外面，不跟着项目滚走")
    func chooseOtherStaysPinnedBelowTheList() async throws {
        let projects = (1...40).map {
            ProjectDirectory(path: "/tmp/项目-\($0)", lastUsed: .distantPast, hasSessions: true)
        }
        let height: CGFloat = 300
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: NewTaskForm(projects: projects,
                                                          bottomInset: PanelCard.bottomInset,
                                                          onSubmit: { _, _ in }, onCancel: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: 560, height: height)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let scroll = try #require(Self.scrollView(in: hosting), "项目列表不再是可滚的了")
        let scrollFrame = scroll.convert(scroll.bounds, to: hosting)
        let below = height - scrollFrame.maxY

        // 钉住时下面依次是：选择其他目录（约 28）+ 分隔线（1）+ 指令框（约 34）
        // + 卡片下边距（8）。挪回列表里就少掉那 28 —— 40 这条线把两种排法分得很开。
        #expect(below > 60, "滚动列表下面只剩 \(Int(below))pt —— 「选择其他目录…」被卷进列表了")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = scrollView(in: sub) { return scroll }
        }
        return nil
    }

    // MARK: - §1.6：悬停只做轻微提亮

    /// 鼠标停在岛上：**只提亮一点点，形状一点不动**。
    ///
    /// 「不展开、不预览」是 spec 3.1 定的。这条盯两件事：亮度确实变了
    /// （没变说明悬停反馈根本没接上，用户会觉得岛是死的），
    /// 以及岛的轮廓一个像素都没动（一动就是「悬停偷偷改了状态」）。
    @Test("悬停只让岛亮一点点，形状不动")
    func hoverOnlyBrightensTheIsland() throws {
        let idle = IslandModel.previewModel(state: .idle)
        let hovered = IslandModel.previewModel(state: .idle)
        hovered.isHovering = true

        let size = canvas(around: idle)
        let plain = try raster(IslandShell(model: idle), size: size)
        let lit = try raster(IslandShell(model: hovered), size: size)

        // 取岛体正中一块，比平均灰度。
        let box = (x: plain.width / 2 - 60, y: 8, w: 40, h: 10)
        func mean(_ image: Raster) -> CGFloat {
            var total: CGFloat = 0
            for y in box.y..<(box.y + box.h) {
                for x in box.x..<(box.x + box.w) { total += image.gray(x, y) }
            }
            return total / CGFloat(box.w * box.h)
        }
        let before = mean(plain)
        let after = mean(lit)
        #expect(after > before, "悬停没有任何提亮：\(before) → \(after)")
        #expect(after - before < 0.12, "悬停亮得太多了（\(before) → \(after)），这已经不是「轻微」了")

        // 轮廓一点不动：两张图里岛的边界必须落在同一列。
        let row = 20
        let plainLeft = try #require(plain.firstNonBackdrop(row: row))
        let litLeft = try #require(lit.firstNonBackdrop(row: row))
        #expect(plainLeft == litLeft, "悬停把岛的形状也改了")
    }


}
