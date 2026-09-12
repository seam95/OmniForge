import XCTest
@testable import OmniForge

/// 气泡载置纯函数测试：上方默认、顶部翻转、水平 clamp、屏底兜底。
final class PetBubblePlacementTests: XCTestCase {
    /// 与 Manager 测试同口径的虚拟屏（可见区 maxY = 825）。
    private let screen = PetScreenGeometry(
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
        identifier: "display-1"
    )
    private let bubbleSize = CGSize(width: 80, height: 30)

    func test_defaultAbovePetCentered() {
        let petFrame = CGRect(x: 100, y: 100, width: 96, height: 96)

        let result = PetBubblePlacement.resolve(
            petFrame: petFrame, bubbleSize: bubbleSize, screen: screen
        )

        XCTAssertTrue(result.tailDown, "上方放得下时尾巴朝下指向宠物")
        XCTAssertEqual(result.frame, CGRect(x: 108, y: 204, width: 80, height: 30))
    }

    func test_flipsBelowWhenTopDoesNotFit() {
        // 宠物贴屏顶（maxY 896 + gap + 30 > 825）：翻到下方、尾巴朝上。
        let petFrame = CGRect(x: 100, y: 800, width: 96, height: 96)

        let result = PetBubblePlacement.resolve(
            petFrame: petFrame, bubbleSize: bubbleSize, screen: screen
        )

        XCTAssertFalse(result.tailDown)
        XCTAssertEqual(result.frame, CGRect(x: 108, y: 762, width: 80, height: 30))
    }

    func test_clampsHorizontallyIntoScreen() {
        // 宠物贴右缘：气泡 preferredX 1408 超出，clamp 到 1440-2-80。
        let petFrame = CGRect(x: 1400, y: 100, width: 96, height: 96)
        let right = PetBubblePlacement.resolve(
            petFrame: petFrame, bubbleSize: bubbleSize, screen: screen
        )
        XCTAssertEqual(right.frame.origin.x, 1358)

        // 宠物贴左缘：preferredX 为负，clamp 到左边距 2。
        let leftPet = CGRect(x: 0, y: 100, width: 60, height: 60)
        let left = PetBubblePlacement.resolve(
            petFrame: leftPet, bubbleSize: bubbleSize, screen: screen
        )
        XCTAssertEqual(left.frame.origin.x, 2)
    }

    func test_bottomFallbackClampsToScreenFloor() {
        // 矮屏场景：上方放不下、下方也放不下 → clamp 到屏底，允许与宠物重叠。
        let shortScreen = PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 140),
            identifier: "display-2"
        )
        let petFrame = CGRect(x: 100, y: 25, width: 96, height: 130)

        let result = PetBubblePlacement.resolve(
            petFrame: petFrame, bubbleSize: bubbleSize, screen: shortScreen
        )

        XCTAssertFalse(result.tailDown)
        XCTAssertEqual(result.frame.origin.y, 25, "兜底贴屏底（可见区底边）")
    }
}
