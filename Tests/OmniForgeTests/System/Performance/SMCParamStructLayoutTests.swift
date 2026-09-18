import XCTest
@testable import OmniForgeSMC

/// SMCParamStruct 与 AppleSMC 驱动用户态 ABI 的布局契约。
/// 曾经 padding 被放宽为 UInt16，导致 result/status/data8 偏移整体后移，
/// 全部 SMC 读取静默失败——用偏移断言防止再次漂移。
final class SMCParamStructLayoutTests: XCTestCase {
    func test_stride_matchesDriverABI() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
    }

    func test_commandFields_matchDriverABIOffsets() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 38, "驱动在偏移 38 写返回码")
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.status), 39)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 40, "驱动在偏移 40 读命令码")
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }
}
