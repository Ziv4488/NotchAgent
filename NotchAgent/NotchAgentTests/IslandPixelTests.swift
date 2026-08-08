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

        /// 岛自己（岛体、外沿那两条线、卡片）—— **不含阴影**。
        ///
        /// 岛外面挂了一圈阴影之后，「不是底色」不再等于「是岛」：贴着岛的那一圈
        /// 品红被压暗了，照样不是底色。
        ///
        /// **只能按绿色分。** 品红是 `(v, 0, v)`，红蓝相等 —— 拿「中性」或者
        /// 「够暗」去判，被阴影压到三成的品红一样能混进来。绿色是它唯一始终为 0
        /// 的通道，而岛这边（纯黑、亮线、卡片）三通道一律相等。
        func isIsland(_ x: Int, _ y: Int) -> Bool {
            let c = color(x, y)
            return abs(c.redComponent - c.greenComponent) < 0.12
                && abs(c.greenComponent - c.blueComponent) < 0.12
        }

        /// 从左往右第一个属于岛的像素 —— 也就是岛的左边界。
        func firstIsland(row y: Int) -> Int? {
            (0..<width).first { isIsland($0, y) }
        }

        /// 品红被压暗了多少 —— 阴影的浓度。底色的红是满的，压暗多少就是多少。
        func darkening(_ x: Int, _ y: Int) -> CGFloat {
            1 - color(x, y).redComponent
        }

        /// 从 `x0` 往右第一个卡片像素。
        ///
        /// **`x0` 不能是 0。** 岛的外沿那条亮线是白 20% 叠在纯黑上 = 灰度 0.2，
        /// 中性、又落在 `isCard` 那档灰里 —— 从最左边扫的话第一个"卡片像素"
        /// 会是岛自己的边，量出来的黑边宽度恒等于 0。调用方要跳过外沿那几 pt。
        func firstCard(row y: Int, from x0: Int = 0) -> Int? {
            (max(0, x0)..<width).first { isCard($0, y) }
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
    ///
    /// `scale` 只在量**亚像素**的东西时才抬到 2：外沿那条黑线只有 0.5pt，
    /// scale 1 下它连一个像素都占不满，量到的永远是它和底色掺出来的中间值。
    private func raster(_ view: some View, size: CGSize,
                        backdrop: Color = IslandPixelTests.backdrop,
                        scale: CGFloat = 1) throws -> Raster {
        let root = ZStack(alignment: .top) {
            backdrop
            view
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: root)
        renderer.scale = scale
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

    /// §10.10c：**会话结束之后，岛的下边框还是 8pt。**
    ///
    /// 这条量的是整块岛（`IslandShell`），不是单独一个 `ContentArea` ——
    /// 那 8pt 是从 shell 里一路传下去的（`bottomInset:`），传丢了这条才红。
    ///
    /// 结束态原来底下还摞着一条输入框，黑边归它留；输入框 2026-08-04 拆了
    ///（见 `IslandConstants.retiredInputBarHeight`），现在两种情况走的是同一条路。
    @Test("岛的下边框：会话结束之后还是 8pt")
    func islandKeepsItsBottomEdgeAfterTheSessionEnds() throws {
        let model = detachedModel()
        let image = try raster(IslandShell(model: model), size: canvas(around: model))

        let column = cleanColumn(image)
        // **下沿从 `model.size` 算，不从像素找。** 岛外面挂着阴影，「最后一个不是
        // 底色的像素」会落在阴影里、跟着阴影一起下移 —— 那正是这条测试当年栽过的坑。
        let islandBottom = Int(model.size.height) - 1
        // 往上让开 2pt：岛的外沿那条亮线灰度 0.2，`isCard` 也认它（见 `firstCard`）。
        let fillBottom = try #require((0..<(islandBottom - 1)).last { image.isCard(column, $0) })
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
        let islandBottom = Int(model.size.height) - 1
        let fillBottom = try #require((0..<(islandBottom - 1)).last { image.isCard(column, $0) })

        // 只看两条弧**同时存在**的那几行：卡片的弧从它自己的下沿往上一个
        // `cardRadius`，岛的弧从岛的下沿往上一个 `bottomCornerRadius`。
        //
        // 岛的左边界用 `firstIsland` 找，**不是 `firstNonBackdrop`** ——
        // 岛外面那圈阴影也不是底色，拿它当边界量出来的黑边会宽出一大截。
        var gaps: [Int] = []
        for y in (fillBottom - Int(PanelCard.cardRadius))...fillBottom {
            guard y >= 0,
                  let islandLeft = image.firstIsland(row: y),
                  // 让开外沿那 2pt，否则第一个"卡片像素"是岛自己的亮线。
                  let cardLeft = image.firstCard(row: y, from: islandLeft + 2) else { continue }
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

    // MARK: - §1.1 / 1.7：岛的外沿是三层

    /// 岛的外沿从里往外必须是**亮线 → 黑线 → 阴影**三层，一层不少、也不越界。
    ///
    /// 参数与来历见 `IslandTheme` 的「岛的外沿」，量自 macOS 26 系统窗口截图。
    /// 这条钉三件事：
    ///
    /// 1. 轮廓**内侧** 1pt 是白 20%（叠在纯黑岛体上 = 灰度 0.2）
    /// 2. 轮廓**外侧** 0.5pt 是黑 —— 少了它，那条亮线读起来就是灰框不是高光，
    ///    这正是前一版描边被拿掉的原因
    /// 3. 再往外是阴影：贴边处底色明显被压暗，**并且 30pt 之外化得干净** ——
    ///    上一版投影栽的是后半句，一圈洗不掉的黑雾铺满了整块透明画布（§1.7）
    ///
    /// **边界从 `model.size` 算，不从像素找。** 第一版是「从底下往上找第一个
    /// 不是底色的像素」当作岛的下沿 —— 挂上投影之后那个位置跟着投影一起下移，
    /// 检查的带子也跟着走，于是测试照样绿。要查的东西自己会移动检查的地方，
    /// 这种度量一律不能用。岛的尺寸是已知的，直接拿。
    /// **不含 idle。** 那一态整套外沿都不上（见 `idleWearsNoEdges`）。
    @Test("岛的外沿是三层：内亮线、外黑线、再往外阴影化得开",
          arguments: [IslandState.running, .notice, .expanded])
    func islandHasThreeEdgeLayers(state: IslandState) throws {
        let model = IslandModel.previewModel(state: state)
        let size = canvas(around: model)
        // 黑线只有 0.5pt，scale 1 下占不满一个像素 —— 必须渲成 2 倍再量。
        let px = 2
        let image = try raster(IslandShell(model: model), size: size, scale: CGFloat(px))

        // 岛贴着画布顶边、水平居中；两侧的内凹圆弧画在主体之外。
        // 竖直中段取的是直边，不受两个下角的圆弧影响。
        let islandBottom = Int(model.size.height) - 1
        let bodyLeft = Int((size.width - model.size.width) / 2) * px
        let row = islandBottom / 2 * px

        // 内侧 1pt = 2 像素：白 20% 叠在纯黑岛体上，正好是灰度 0.2。
        for step in 0..<px {
            let gray = image.gray(bodyLeft + step, row)
            #expect(abs(gray - 0.2) < 0.04,
                    "轮廓往里第 \(step) 个像素该是白 20% 的亮线，量到灰度 \(gray)")
        }
        // 再往里就是岛体，纯黑。
        #expect(image.gray(bodyLeft + px * 2, row) < 0.05, "亮线不该糊进岛体里")

        // 外侧 0.5pt = 1 像素：不透明的黑。
        #expect(image.gray(bodyLeft - 1, row) < 0.08,
                "轮廓外侧该有一条黑线，量到灰度 \(image.gray(bodyLeft - 1, row))")

        // 阴影：贴边处底色被压暗，再往外化干净。
        // **不能用 `isBackdrop` 判**：它只认「红蓝都高于 0.85」，阴影把品红压暗
        // 一成的地方照样算底色，于是「有没有阴影」这半句根本不会红。看压暗量。
        // 贴边这一下量**下面**：阴影往下偏 6pt，岛的上半截侧面本来就淡
        // （idle 只有一条菜单栏那么高，整块岛都在"上半截"里）。
        let near = image.darkening(image.width / 2, (islandBottom + 4) * px)
        #expect(near > 0.25, "贴着岛下沿的外面该有阴影，那儿只压暗了 \(near)")

        let outerLeft = bodyLeft - Int(model.cornerRadii.inverted) * px
        let far = image.darkening(outerLeft - 45 * px, row)
        #expect(far < 0.03, "岛左边 45pt 之外还压暗着 \(far) —— 阴影没化开")

        // 阴影往下偏 6pt，所以下面这条量得比侧面远。
        var bottomHaze: CGFloat = 0
        for y in ((islandBottom + 55) * px)..<min(image.height, (islandBottom + 70) * px) {
            for x in stride(from: 0, to: image.width, by: px) {
                bottomHaze = max(bottomHaze, image.darkening(x, y))
            }
        }
        #expect(bottomHaze < 0.03,
                "岛下沿 55pt 之外还压暗着 \(bottomHaze) —— 黑雾又回来了")
    }

    /// **岛拖到最大时，阴影得在画布边缘之前化干净。**
    ///
    /// 画布就是那块 `NSWindow`，窗口画不到自己 frame 之外去。以前画布只比岛能长到的
    /// 最大宽度多出两个内凹半径（每边 8pt），岛一旦拖到最大，阴影就在 8pt 处被齐齐
    /// 切断 —— 贴着岛留下一条外沿是刀切直线的黑带，正是用户 2026-08-04 报的
    /// 「拖到一定大小（大），会出现一条不一样的黑边」。量他那张截图：壁纸亮度
    /// 在一个像素之内从 76% 跳回 100%。
    ///
    /// 所以这条**必须按 `containerFrame` 的尺寸渲**，不能用 `canvas(around:)` 那块
    /// 宽松画布 —— 宽松画布上阴影哪儿都化得开，切没切根本量不出来。
    @Test("岛拖到最大：阴影在画布边缘之前化干净")
    func shadowFitsInsideTheCanvasAtMaximumSize() throws {
        let model = IslandModel.previewModel(state: .expanded)
        model.resizeExpanded(width: model.expandedWidthRange.upperBound,
                             contentHeight: model.expandedContentHeightRange.upperBound)
        let size = model.metrics.containerFrame.size
        let image = try raster(IslandShell(model: model), size: size)

        let row = Int(model.size.height) / 2
        let bodyLeft = Int((size.width - model.size.width) / 2)

        // 先确认这张图上**真的有阴影** —— 否则下面三条在一张没投影的图上全绿。
        let near = image.darkening(bodyLeft - 3, row)
        #expect(near > 0.15, "岛左沿外 3pt 只压暗了 \(near)，这张图根本没画阴影")

        // 画布最左、最右那一列。被切的话这儿正是断口，压得很暗。
        #expect(image.darkening(0, row) < 0.02,
                "画布左边缘还压暗着 \(image.darkening(0, row)) —— 阴影被窗口切了")
        #expect(image.darkening(image.width - 1, row) < 0.02,
                "画布右边缘还压暗着 \(image.darkening(image.width - 1, row))")
        // 下边缘同理，避开正中那条拖拽提示横条。
        let column = cleanColumn(image)
        #expect(image.darkening(column, image.height - 1) < 0.02,
                "画布下边缘还压暗着 \(image.darkening(column, image.height - 1))")
    }

    /// **顶边不描线。**
    ///
    /// 岛的顶边正好压在屏幕物理上沿，一条描边只有内侧那半截露得出来 ——
    /// 画出来是刘海底下横着一道亮痕（用户 2026-08-04：「上方边缘不要边界」）。
    /// 靠 `NotchShape.closesTop` 关掉：描的是一条开放轮廓，顶边那一段根本不在路径里。
    ///
    /// 取样点选**刘海正中那一列**：那儿状态带一个字都没有
    ///（`statusBandTextStaysOutOfTheNotch` 钉着这件事），亮起来只可能是描边。
    @Test("岛的顶边不描线", arguments: [IslandState.running, .expanded])
    func topEdgeIsNotStroked(state: IslandState) throws {
        let model = IslandModel.previewModel(state: state)
        let size = canvas(around: model)
        let px = 2
        let image = try raster(IslandShell(model: model), size: size, scale: CGFloat(px))
        let column = image.width / 2

        // 亮线画在轮廓内侧 1pt —— 顶边要是描了，就是最上面这 1pt。
        for y in 0..<(px * Int(IslandTheme.edgeHighlightWidth)) {
            #expect(image.gray(column, y) < 0.05,
                    "顶边往下第 \(y) 行灰度 \(image.gray(column, y))，顶边又描上了")
        }

        // 反过来确认这张图**真的画了外沿** —— 否则这条是靠「三层全丢了」蒙过去的。
        let bodyLeft = Int((size.width - model.size.width) / 2) * px
        let side = image.gray(bodyLeft + 1, Int(model.size.height) / 2 * px)
        #expect(abs(side - 0.2) < 0.04, "侧边根本没有亮线（\(side)），这条测试等于没测")
    }

    /// **idle 态整套外沿都不上。**
    ///
    /// 那时候岛就是刘海本身（高正好一条菜单栏），沿着它描一圈亮线再挂一层阴影，
    /// 读起来是「屏幕顶上浮着一根黑条」而不是刘海。用户 2026-08-04 的原话是
    /// 「ideal 态的时候按照之前的边缘方案」—— 回到 08-02 那版，纯黑一块。
    @Test("idle 态不描边、不投影")
    func idleWearsNoEdges() throws {
        let model = IslandModel.previewModel(state: .idle)
        let size = canvas(around: model)
        let px = 2
        let image = try raster(IslandShell(model: model), size: size, scale: CGFloat(px))

        let islandBottom = Int(model.size.height) - 1
        let bodyLeft = Int((size.width - model.size.width) / 2) * px
        let row = islandBottom / 2 * px

        // 岛确实画出来了 —— 不然下面两条在一张空白品红上也是绿的。
        #expect(image.isIsland(image.width / 2, 4), "idle 的岛根本没画出来")

        // 轮廓内侧那 1pt：有亮线的话是灰度 0.2。
        let side = image.gray(bodyLeft + 1, row)
        #expect(side < 0.05, "idle 的侧边灰度 \(side) —— 亮线跑上来了")

        // 贴着下沿外面：有阴影的话这儿会被压暗两成以上。
        let near = image.darkening(image.width / 2, (islandBottom + 4) * px)
        #expect(near < 0.03, "idle 的岛下面压暗了 \(near) —— 阴影跑上来了")
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
        idle.hoverBehavior = .highlight
        let hovered = IslandModel.previewModel(state: .idle)
        hovered.isHovering = true
        hovered.hoverBehavior = .highlight

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
        // 用 `firstIsland` 而不是「第一个不是底色的像素」——
        // 后者现在会先撞上岛外那圈阴影，量的就不是轮廓了。
        let plainLeft = try #require(plain.firstIsland(row: row))
        let litLeft = try #require(lit.firstIsland(row: row))
        #expect(plainLeft == litLeft, "悬停把岛的形状也改了")
    }

    // MARK: - §13.13：拖动中的 tab 芯片不透光

    /// 拖着一个 tab 走的时候，它**不能**是半透明的。
    ///
    /// 芯片本来只有选中时才有背景、而且是白 11% 的半透明；拖过邻居时两边的字
    /// 直接叠在一起（用户 08-04 报的「tab 之间的内容有穿插」）。没选中的那个
    /// 更彻底 —— 整块全透，拖起来就是一行字在另一行字上面走。
    ///
    /// 量法：把芯片渲在品红上，数芯片框里还剩多少品红。垫上不透明底之后是 0。
    /// 同一张图里顺带量了**没垫**的那一版 —— 它必须漏，不漏说明这条测的不是
    /// 这件事（比如芯片自己长了个不透明背景，那这条测试就白写了）。
    @Test("拖动中的 tab 芯片不透光")
    func draggedChipDoesNotLetTheBackdropThrough() throws {
        let tab = IslandTab(title: "写测试", kind: .cli, status: .running, accent: .orange)
        // 画布正好是芯片渲染出来的大小 —— 大了的话四周那圈空白也是品红，
        // 数出来的漏光就不是芯片的了。
        let size = CGSize(width: TabStrip.chipWidth(for: tab),
                          height: TabStrip.Layout.stripHeight)

        func magentaCount(backing: Color?) throws -> Int {
            let image = try raster(TabChip(tab: tab, isSelected: false, backing: backing),
                                   size: size)
            // 芯片顶在画布上沿、水平居中。四边各让开 3pt 躲开圆角的抗锯齿，
            // 下面让开的是芯片本身没占满的那几 pt（它比 stripHeight 矮一点）。
            var count = 0
            let chipHeight = TabStrip.Layout.chipVPadding * 2 + TabStrip.Layout.iconSize
            for y in 3..<(Int(chipHeight) - 3) {
                for x in 3..<(image.width - 3) where image.isBackdrop(x, y) { count += 1 }
            }
            return count
        }

        #expect(try magentaCount(backing: .black) == 0, "垫了不透明底，芯片还在漏光")
        #expect(try magentaCount(backing: nil) > 0,
                "没垫底的芯片居然也不漏 —— 那这条测的就不是「垫底」这件事")
    }

    // MARK: - §13.17：tab 芯片是胶囊

    /// 芯片的两头是**半圆**，不是圆角矩形的角（用户 2026-08-04 给了参考截图）。
    ///
    /// **量的是「拖动中那层不透明底」**，不是选中态那层白 11%。后者是半透明的，
    /// 叠在品红上算出来是 `(1, 0.11, 1)` —— 还是品红色调，`isIsland` 一个都不认，
    /// 逐行找到的"第一个中性像素"会是芯片**里面的字**。第一版就是这么写的，
    /// 于是把 `Capsule` 换回 8pt 圆角矩形它照样绿：它量的根本不是形状。
    /// `backing` 那层是同一个 `Capsule`、但不透光，轮廓之内一律是黑。
    ///
    /// 判据是**距顶 2.5pt 处左边缘内收多少**。芯片高 22pt，胶囊半径就是 11pt，
    /// 那儿该收 4.5pt；原来写死的 8pt `.continuous` 圆角在同一处只收 2.25pt。
    /// （`.continuous` 的角**没有**贴着 0 的直边 —— 8pt 的角在 22pt 高上左右两个
    /// 已经接上了，所以不能拿「直边有多长」当判据。）
    @Test("tab 芯片是胶囊：两头是半圆")
    func chipIsACapsule() throws {
        let tab = IslandTab(title: "写测试", kind: .cli, status: .running, accent: .orange)
        let size = CGSize(width: TabStrip.chipWidth(for: tab),
                          height: TabStrip.Layout.stripHeight)
        // 判据差在 2pt 上下，scale 1 量不准 —— 渲成 4 倍，一个像素是 0.25pt。
        let px = 4
        let image = try raster(TabChip(tab: tab, isSelected: false, backing: .black),
                               size: size, scale: CGFloat(px))

        func inset(atY y: CGFloat) throws -> CGFloat {
            let x = try #require(image.firstIsland(row: Int(y * CGFloat(px))),
                                 "距顶 \(y)pt 那一行没量到芯片")
            return CGFloat(x) / CGFloat(px)
        }

        let near = try inset(atY: 2.5)
        #expect(near > 3.5, "距顶 2.5pt 处左边缘只内收了 \(near)pt —— 这是圆角矩形的角，不是半圆")

        // 正中那行必须贴到 0，否则量到的压根不是轮廓。
        let middle = try inset(atY: TabStrip.Layout.chipVPadding + TabStrip.Layout.iconSize / 2)
        #expect(middle < 0.5, "芯片正中的左边缘在 \(middle)pt —— 量到的不是轮廓")
    }

}
