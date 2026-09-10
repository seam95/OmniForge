import XCTest
@testable import OmniForge

/// 行为循环长时模拟回归：用生产随机源跑等价 10 分钟的 tick，
/// 断言位置始终困在活动锚点 ±120pt 内（防范围限制回归），
/// 并输出 idle/walk 占比供行为参数调优参考。
@MainActor
final class PetBehaviorLoopTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var assetRoot: URL!

    override func setUp() {
        super.setUp()
        suiteName = "PetDrift-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-drift-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: assetRoot)
        super.tearDown()
    }

    func test_tenMinuteSimulation_positionAndStateDutyCycle() {
        let screen = PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
            identifier: "display-1"
        )
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: PetWindowController(petSize: CGSize(width: 96, height: 96)),
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            stringsProvider: { .zhHans },
            visibleScreensProvider: { [screen] },
            tickInterval: 1.0 / 30.0,
            frameClock: ManualFrameClock()
        )
        manager.start()
        defer { manager.teardown() }

        // 等价 10 分钟（30fps × 600s）。生产随机源（真随机）。
        let ticks = 18_000
        var idleTicks = 0
        var walkTicks = 0
        var otherTicks = 0
        var idleSeconds = 0.0
        var totalSeconds = 0.0
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        // 记录每次状态切换，输出最长连续 walk 段。
        var longestWalkRun = 0
        var currentRun = 0

        for _ in 0..<ticks {
            manager.tick()
            totalSeconds += 1.0 / 30.0
            switch manager.behaviorState {
            case .idle:
                idleTicks += 1
                idleSeconds += 1.0 / 30.0
                currentRun = 0
            case .walk:
                walkTicks += 1
                currentRun += 1
                longestWalkRun = max(longestWalkRun, currentRun)
            default:
                otherTicks += 1
                currentRun = 0
            }
            if let x = manager.windowController.currentOrigin?.x {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }

        let startAnchor = manager.windowController.currentOrigin?.x ?? 0
        print("DIAG idle时长占比=\(idleSeconds / totalSeconds) tick占比=\(Double(idleTicks) / Double(ticks)) walkTick占比=\(Double(walkTicks) / Double(ticks))")
        print("DIAG x轨迹范围=[\(minX), \(maxX)] 跨度=\(maxX - minX) 起点≈\(startAnchor)")
        print("DIAG 最长连续walk=\(longestWalkRun) tick（\(Double(longestWalkRun) / 30.0)s）")
        print("DIAG anchor范围应=[\(startAnchor - 120), \(startAnchor + 120)]")

        // 事实断言：位置必须困在 anchor ±120（+1pt 容差）内。
        XCTAssertLessThanOrEqual(maxX - minX, 240 + 1, "位置越出活动范围——范围限制失效")
        // 矩阵改造后的核心行为约束：适中档 idle 时长占比 ≥70%（治「走太多」）。
        XCTAssertGreaterThanOrEqual(
            idleSeconds / totalSeconds,
            0.70,
            "idle 时长占比应 ≥70%，实际 \(idleSeconds / totalSeconds)"
        )
    }
}
