import Foundation
import XCTest
@testable import OmniForge

/// B 类（本地 SQLite）采集器基类共享工具的回归测试：
/// 桶对齐必须统一走时间戳清洗器，脏数据（巨值/非正数）不得触发 Int(Double) trap。
final class SQLiteUsageCollectorBaseTests: XCTestCase {
    // MARK: - bucketStart(fromMilliseconds:)

    /// 巨值脏数据（1e22 毫秒级，常见于 SQLite 脏 REAL 列）：返回 nil，绝不崩溃。
    func testBucketStartRejectsHugeMillisecondsWithoutCrashing() {
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: 1e22))
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: .infinity))
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: .nan))
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: nil))
    }

    /// 0 与负数时间戳：拒绝（返回 nil）。
    func testBucketStartRejectsNonPositiveMilliseconds() {
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: 0))
        XCTAssertNil(SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: -5))
    }

    /// 正常毫秒时间戳：对齐到 UTC 1800 秒（半小时）桶起点边界。
    func testBucketStartAlignsToHalfHourBoundary() {
        // 1_784_502_600_000 ms → 1_784_502_600 s → 向下对齐 991_390 * 1800 = 1_784_502_000 s。
        let start = SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: 1_784_502_600_000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_502_000))

        // 恰好落在桶边界：原样返回。
        let exact = SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: 1_784_502_000_000)
        XCTAssertEqual(exact, Date(timeIntervalSince1970: 1_784_502_000))

        // 桶内最后 1 秒（1_784_503_799 s）：仍对齐到同一桶起点。
        let lastSecond = SQLiteUsageCollectorBase.bucketStart(fromMilliseconds: 1_784_503_799_000)
        XCTAssertEqual(lastSecond, Date(timeIntervalSince1970: 1_784_502_000))
    }
}
