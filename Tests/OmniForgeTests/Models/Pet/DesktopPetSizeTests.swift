import XCTest
@testable import OmniForge

/// 连续尺寸模型测试：真实旧整数兼容、缺失/非法值回退、钳制与半步取整、重启保持。
final class DesktopPetSizeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DesktopPetSizeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 旧偏好兼容

    func test_legacyIntegerPreferencesStayUnchanged() {
        // 真实旧三档整数原样保留（升级后尺寸不变）。
        XCTAssertEqual(DesktopPetSize.from(64), DesktopPetSize.small)
        XCTAssertEqual(DesktopPetSize.from(96), DesktopPetSize.medium)
        XCTAssertEqual(DesktopPetSize.from(128), DesktopPetSize.large)
        XCTAssertEqual(DesktopPetSize.small.rawValue, 64)
        XCTAssertEqual(DesktopPetSize.medium.rawValue, 96)
        XCTAssertEqual(DesktopPetSize.large.rawValue, 128)
    }

    // MARK: - 缺失 / 非法值

    func test_missingKeyFallsBackToDefault() {
        // 键缺失（未写入）→ 默认 96，不依赖 integer(forKey:) 的缺省 0。
        XCTAssertEqual(
            DesktopPetSize.read(from: defaults, key: "pet.size.test"),
            DesktopPetSize.medium
        )
    }

    func test_nonNumericStoredValueFallsBackToDefault() {
        defaults.set("not-a-number", forKey: "pet.size.test")
        XCTAssertEqual(
            DesktopPetSize.read(from: defaults, key: "pet.size.test"),
            DesktopPetSize.medium,
            "字符串等非数值回退默认"
        )
    }

    func test_realZeroIsClampedNotDefaulted() {
        // 真实 0（有限值）钳到下限 64——与缺失键的回退 96 可区分。
        defaults.set(0, forKey: "pet.size.test")
        XCTAssertEqual(
            DesktopPetSize.read(from: defaults, key: "pet.size.test"),
            DesktopPetSize(64),
            "真实 0 是有限越界值，钳制而非回退默认"
        )
    }

    // MARK: - 钳制与取整

    func test_outOfRangeValuesAreClamped() {
        XCTAssertEqual(DesktopPetSize.from(10), DesktopPetSize(64))
        XCTAssertEqual(DesktopPetSize.from(300), DesktopPetSize(224))
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 1_000_000), DesktopPetSize(224))
    }

    func test_halfStepRoundsUp() {
        // 66 / 4 = 16.5 → 17 × 4 = 68（半步向上）；65 → 16.25 → 64。
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 66), DesktopPetSize(68))
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 65), DesktopPetSize(64))
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 94), DesktopPetSize(96))
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 93.9), DesktopPetSize(92))
        XCTAssertEqual(DesktopPetSize.normalized(clamping: 222), DesktopPetSize(224))
    }

    func test_nonFiniteFallsBackToDefault() {
        XCTAssertEqual(DesktopPetSize.normalized(clamping: .nan), DesktopPetSize.medium)
        XCTAssertEqual(DesktopPetSize.normalized(clamping: .infinity), DesktopPetSize.medium)
    }

    // MARK: - 连续值保持

    func test_continuousValueSurvivesSaveAndReread() {
        // 新连续值（如 112）写入后重读保持（重启记忆）。
        defaults.set(112, forKey: "pet.size.test")
        XCTAssertEqual(DesktopPetSize.read(from: defaults, key: "pet.size.test").rawValue, 112)
        // 非步进倍数值读取时取整到最近步进（半步向上：110 → 112）。
        defaults.set(110.0, forKey: "pet.size.test")
        XCTAssertEqual(DesktopPetSize.read(from: defaults, key: "pet.size.test").rawValue, 112)
    }
}

// MARK: - 相等性（struct 迁移回归）

extension DesktopPetSizeTests {
    func test_equalityAndHashableSemantics() {
        XCTAssertEqual(DesktopPetSize(96), DesktopPetSize(96))
        XCTAssertNotEqual(DesktopPetSize(96), DesktopPetSize(128))
        XCTAssertEqual(Set([DesktopPetSize(96), DesktopPetSize(96)]).count, 1)
    }
}
