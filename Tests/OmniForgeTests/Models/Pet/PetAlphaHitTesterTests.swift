import CoreGraphics
import XCTest
@testable import OmniForge

/// alpha 命中测试：非对称帧（Y 翻转 / 水平镜像）、容差邻域、非正方形缩放、
/// alpha 阈值、缓存与兜底语义。
@MainActor
final class PetAlphaHitTesterTests: XCTestCase {
    private var tester: PetAlphaHitTester!

    override func setUp() {
        super.setUp()
        tester = PetAlphaHitTester()
    }

    // MARK: - 测试帧构造

    /// 构造 32×32 帧：实体只占**下半**（判定 Y 翻转——AppKit 本地 y 向上，
    /// 帧像素 y 向下：帧下半实体 = 窗口上半可命中）。
    private func bottomHalfFrame() -> CGImage {
        frame(width: 32, height: 32) { context in
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
    }

    /// 构造 32×32 帧：实体只占**左半**（判定镜像换算）。
    private func leftHalfFrame() -> CGImage {
        frame(width: 32, height: 32) { context in
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        }
    }

    /// 构造实体只占中心 4×4 的帧（判定容差内外边界）。
    private func centerDotFrame() -> CGImage {
        frame(width: 32, height: 32) { context in
            context.fill(CGRect(x: 14, y: 14, width: 4, height: 4))
        }
    }

    /// 构造 alpha = 8（阈值边界，不命中：要求 > 8）与 alpha = 9（命中）的帧。
    private func thresholdFrame(alpha: CGFloat) -> CGImage {
        frame(width: 32, height: 32) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func frame(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            draw(context)
            return context.makeImage()
        }
        return unwrap(image)
    }

    private func unwrap(_ image: CGImage?) -> CGImage {
        guard let image else { fatalError("测试帧构造失败") }
        return image
    }

    /// 96×96 显示（1:3 缩放）的快照。
    private func snapshot(
        mirrored: Bool = false,
        size: CGSize = CGSize(width: 96, height: 96)
    ) -> PetDisplaySnapshot {
        let asset = PetSpriteAsset(
            id: "hit-pet",
            displayName: "Hit Pet",
            atlasFileName: "atlas.png",
            grid: PetSpriteAsset.Grid(columns: 8, rows: 9, cellWidth: 32, cellHeight: 32),
            animations: [
                PetSpriteAsset.Animation(id: PetAnimationID.idle, frames: [0], fps: 4, loops: true, mirrorX: false)
            ]
        )
        return PetDisplaySnapshot(
            asset: asset, frameIndex: 0, mirrored: mirrored, size: size
        )
    }

    // MARK: - Y 翻转与非对称

    func test_bottomHalfFrameHitsOnlyLowerHalfInWindowCoordinates() {
        let snapshot = snapshot()
        let frame = bottomHalfFrame()
        // 帧下半实体 → 显示在窗口下半（本地 y 向上、帧行向下，Y 已翻转换算）。
        XCTAssertTrue(tester.contains(CGPoint(x: 48, y: 10), snapshot: snapshot, frameImage: frame), "窗口下半（帧底实体）命中")
        XCTAssertFalse(tester.contains(CGPoint(x: 48, y: 80), snapshot: snapshot, frameImage: frame), "窗口上半（帧顶透明）不命中")
    }

    // MARK: - 水平镜像

    func test_mirroredSnapshotFlipsHorizontalAxis() {
        let snapshot = snapshot(mirrored: true)
        let frame = leftHalfFrame()
        // 帧左半实体：镜像后窗口右半命中。
        XCTAssertTrue(tester.contains(CGPoint(x: 80, y: 48), snapshot: snapshot, frameImage: frame), "镜像后右半命中")
        XCTAssertFalse(tester.contains(CGPoint(x: 10, y: 48), snapshot: snapshot, frameImage: frame), "镜像后左半不命中")
    }

    // MARK: - 容差

    func test_toleranceRingAroundCenterDot() {
        // 96pt 显示 / 32px 帧：1pt = 1/3px；容差 6pt → 膨胀半径 2px。
        // 中心 dot 占帧 px 14…17（本地 42…51），膨胀后覆盖 px 12…19（本地 36…57）。
        let snapshot = snapshot()
        let frame = centerDotFrame()
        // 中心命中。
        XCTAssertTrue(tester.contains(CGPoint(x: 46, y: 46), snapshot: snapshot, frameImage: frame))
        // 膨胀边缘（本地 58 ≈ px 19）：命中。
        XCTAssertTrue(tester.contains(CGPoint(x: 58, y: 46), snapshot: snapshot, frameImage: frame), "容差内命中")
        // 膨胀外（本地 60 → px 20）：不命中。
        XCTAssertFalse(tester.contains(CGPoint(x: 60, y: 46), snapshot: snapshot, frameImage: frame), "容差外不命中")
        // 斜向（54,54）→ px(18,18)：距实体格 (17,17) 对角 √2 < 2：命中（完整邻域查询）。
        XCTAssertTrue(tester.contains(CGPoint(x: 54, y: 54), snapshot: snapshot, frameImage: frame), "斜向邻域命中")
    }

    func test_smallDisplayUsesLargerTolerance() {
        // 64pt（≤72）用 8pt 容差；1pt = 0.5px → 膨胀半径 4px。
        // dot 中心本地 (31,31)（px 14…17），膨胀后本地 20…42。
        let snapshot = snapshot(size: CGSize(width: 64, height: 64))
        let frame = centerDotFrame()
        // 距实体右缘 6pt（本地 37 → px 18.5）：膨胀内命中。
        XCTAssertTrue(tester.contains(CGPoint(x: 37, y: 31), snapshot: snapshot, frameImage: frame))
        // 本地 45 → px 22.5：膨胀外（实体+4px = 本地 42）不命中。
        XCTAssertFalse(tester.contains(CGPoint(x: 45, y: 31), snapshot: snapshot, frameImage: frame))
    }

    // MARK: - alpha 阈值

    func test_alphaThresholdIsExclusiveAboveEight() {
        let snapshot = snapshot()
        // alpha 恰 8：不命中（要求 > 8）。
        XCTAssertFalse(
            tester.contains(CGPoint(x: 48, y: 48), snapshot: snapshot, frameImage: thresholdFrame(alpha: 8.0 / 255.0)),
            "alpha == 8 不算实体"
        )
        // 同帧号的另一帧位图（alpha 9）：缓存键相同，先清缓存再验（真实场景位图随资产替换整体失效）。
        tester.clearCache()
        XCTAssertTrue(
            tester.contains(CGPoint(x: 48, y: 48), snapshot: snapshot, frameImage: thresholdFrame(alpha: 9.0 / 255.0)),
            "alpha == 9 算实体"
        )
    }

    // MARK: - 非正方形与窗口外

    func test_nonSquareDisplayScalesAxesIndependently() {
        // 48×96 显示（宽高比 1:2）：x 轴 1pt=2/3px，y 轴 1pt=1/3px。
        let snapshot = snapshot(size: CGSize(width: 48, height: 96))
        let frame = bottomHalfFrame()
        XCTAssertTrue(tester.contains(CGPoint(x: 24, y: 20), snapshot: snapshot, frameImage: frame))
        XCTAssertFalse(tester.contains(CGPoint(x: 24, y: 70), snapshot: snapshot, frameImage: frame))
    }

    func test_pointOutsideWindowRectNeverHits() {
        let snapshot = snapshot()
        let frame = thresholdFrame(alpha: 1)
        XCTAssertFalse(tester.contains(CGPoint(x: -1, y: 48), snapshot: snapshot, frameImage: frame), "窗口左侧外")
        XCTAssertFalse(tester.contains(CGPoint(x: 96.5, y: 48), snapshot: snapshot, frameImage: frame), "窗口右侧外（容差不越窗界）")
    }

    // MARK: - 兜底与缓存

    func test_nilFrameImageFallsBackToRectHit() {
        let snapshot = snapshot()
        XCTAssertTrue(
            tester.contains(CGPoint(x: 2, y: 2), snapshot: snapshot, frameImage: nil),
            "帧缺失时矩形兜底（可见占位可操作）"
        )
    }

    func test_cacheInvalidationOnAssetSwap() {
        let snapshot = snapshot()
        let bottom = bottomHalfFrame()
        // 首查缓存下半实体帧：窗口下半命中。
        XCTAssertTrue(tester.contains(CGPoint(x: 48, y: 10), snapshot: snapshot, frameImage: bottom))
        // 清缓存后换上半实体帧：不得复用旧 mask（命中区翻转到窗口上半）。
        tester.clearCache()
        let top = frame(width: 32, height: 32) { context in
            context.fill(CGRect(x: 0, y: 16, width: 32, height: 16))
        }
        XCTAssertFalse(tester.contains(CGPoint(x: 48, y: 10), snapshot: snapshot, frameImage: top), "清缓存后新帧生效")
        XCTAssertTrue(tester.contains(CGPoint(x: 48, y: 80), snapshot: snapshot, frameImage: top))
    }
}
