import Foundation
import XCTest
@testable import OmniForge

/// 文件版本指纹：跨进程持久化后，Date 往返的亚微秒误差不得导致指纹失配。
final class UsageFileSignatureTests: XCTestCase {
    /// 实测样本：文件 attributes 值 1794540475.3116 与存储读回值
    /// 1794540475.3115997 相差约 0.24µs，必须视为同一指纹。
    func test_equality_toleratesSubMillisecondDateDrift() {
        let attributesValue = Date(timeIntervalSince1970: 1_794_540_475.3116)
        let storedValue = Date(timeIntervalSince1970: 1_794_540_475.3115997)
        XCTAssertEqual(
            UsageFileSignature(size: 51_654, modifiedAt: attributesValue),
            UsageFileSignature(size: 51_654, modifiedAt: storedValue)
        )
    }

    /// 大小变化或修改时间变化超过容差时必须识别为不同指纹。
    func test_equality_detectsSizeAndMeaningfulTimeChanges() {
        let base = Date(timeIntervalSince1970: 1_794_540_475.3116)
        XCTAssertNotEqual(
            UsageFileSignature(size: 51_654, modifiedAt: base),
            UsageFileSignature(size: 51_655, modifiedAt: base)
        )
        XCTAssertNotEqual(
            UsageFileSignature(size: 51_654, modifiedAt: base),
            UsageFileSignature(size: 51_654, modifiedAt: base.addingTimeInterval(0.002))
        )
    }
}
