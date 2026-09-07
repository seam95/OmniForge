import XCTest
import OmniForgeSMC

/// 风扇 SMC 命令替身 — 字典驱动读值 + 调用序记录；写 Md/Ftst 后模拟回读变化
final class MockFanSMCCommanding: FanSMCCommanding, SMCKeyEnumerating {
    var uint8Values: [String: UInt8] = [:]
    var uint16Values: [String: UInt16] = [:]
    var doubleValues: [String: Double] = [:]
    var dataSizes: [String: UInt32] = [:]
    var keyNames: [String] = []
    /// 每次 readDouble 调用的 key 记录，供断言「锁定后只读活跃集」
    var readDoubleKeys: [String] = []
    private(set) var writes: [(key: String, bytes: [UInt8])] = []
    var writeError: Error?

    func readUInt8(forKey name: String) -> UInt8? { uint8Values[name] }
    func readUInt16(forKey name: String) -> UInt16? { uint16Values[name] }

    func readDouble(forKey name: String) -> Double? {
        readDoubleKeys.append(name)
        return doubleValues[name]
    }

    func dataSize(forKey name: String) -> UInt32? { dataSizes[name] }

    func write(bytes: [UInt8], forKey name: String) throws {
        if let writeError { throw writeError }
        writes.append((name, bytes))
        // 模拟 SMC 写后回读语义 — 归还路径的 anyFanManual 检查依赖
        if name.hasSuffix("Md") || name == "Ftst" {
            uint8Values[name] = bytes.first ?? 0
        }
    }

    func totalKeyCount() -> Int? { keyNames.count }

    func keyName(at index: Int) -> String? {
        index >= 0 && index < keyNames.count ? keyNames[index] : nil
    }

    var writtenKeys: [String] { writes.map(\.key) }

    func clearWrites() { writes.removeAll() }
}

final class FanSMCWriterTests: XCTestCase {

    private func makeWriter(fanCount: UInt8 = 2) -> (FanSMCWriter, MockFanSMCCommanding) {
        let mock = MockFanSMCCommanding()
        mock.uint8Values["FNum"] = fanCount
        mock.dataSizes["F0Tg"] = 4
        mock.dataSizes["F1Tg"] = 4
        return (FanSMCWriter(smc: mock), mock)
    }

    // MARK: - 写入序列

    func test_setFanSpeed_firstCall_enablesTestModeThenManualThenTarget() throws {
        let (writer, mock) = makeWriter()

        try writer.setFanSpeed(index: 0, rpm: 3200)

        XCTAssertEqual(mock.writtenKeys, ["Ftst", "F0Md", "F0Tg"])
        XCTAssertEqual(mock.writes[0].bytes, [1], "首次写入必须先开测试模式")
        XCTAssertEqual(mock.writes[1].bytes, [1], "随后置手动模式")
        XCTAssertEqual(mock.writes[2].bytes, SMCCodec.encodeFloat32(3200))
    }

    func test_setFanSpeed_usesFPE2_whenTargetKeyIs2Bytes() throws {
        let (writer, mock) = makeWriter()
        mock.dataSizes["F0Tg"] = 2

        try writer.setFanSpeed(index: 0, rpm: 3200)

        XCTAssertEqual(mock.writes.last?.bytes, SMCCodec.encodeFPE2(3200))
    }

    func test_setFanSpeed_subsequentCalls_skipTestMode() throws {
        let (writer, mock) = makeWriter()

        try writer.setFanSpeed(index: 0, rpm: 3200)
        try writer.setFanSpeed(index: 1, rpm: 3400)

        XCTAssertEqual(mock.writtenKeys.filter { $0 == "Ftst" }.count, 1,
                       "测试模式只需开启一次")
    }

    func test_setFanAuto_closesTestMode_whenNoOtherFanManual() throws {
        let (writer, mock) = makeWriter()

        try writer.setFanSpeed(index: 0, rpm: 3200)
        try writer.setFanAuto(index: 0)

        XCTAssertEqual(mock.writtenKeys, ["Ftst", "F0Md", "F0Tg", "F0Md", "Ftst"])
        XCTAssertEqual(mock.writes.last?.bytes, [0], "全部归还后必须关测试模式")
    }

    func test_setFanAuto_keepsTestMode_whenAnotherFanStillManual() throws {
        let (writer, mock) = makeWriter()

        try writer.setFanSpeed(index: 0, rpm: 3200)
        try writer.setFanSpeed(index: 1, rpm: 3400)
        try writer.setFanAuto(index: 0)

        XCTAssertEqual(mock.writtenKeys.filter { $0 == "Ftst" }.count, 1,
                       "仍有风扇手动时不得关测试模式")
    }

    func test_resetAllFans_writesAllModesAndClosesTestMode() throws {
        let (writer, mock) = makeWriter(fanCount: 3)

        try writer.setFanSpeed(index: 1, rpm: 3000)
        mock.clearWrites()
        try writer.resetAllFansToAuto()

        XCTAssertEqual(mock.writtenKeys, ["F0Md", "F1Md", "F2Md", "Ftst"])
        XCTAssertTrue(mock.writes.dropLast().allSatisfy { $0.bytes == [0] })
        XCTAssertEqual(mock.writes.last?.bytes, [0])
    }

    // MARK: - 编解码

    func test_encodeFPE2_roundTrip() {
        // 3200 × 4 = 12800 = 0x3200 → 高字节 0x32、低字节 0x00
        XCTAssertEqual(SMCCodec.encodeFPE2(3200), [0x32, 0x00])
        XCTAssertEqual(SMCCodec.encodeFPE2(0), [0x00, 0x00])
        // 超出 14 位上限钳到 UInt16.max
        XCTAssertEqual(SMCCodec.encodeFPE2(1_000_000), [0xFF, 0xFF])
    }

    func test_encodeFloat32_littleEndian() {
        // 3400.0 的 float32 位模式按小端展开
        let bits = Float(3400).bitPattern
        let expected = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                        UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        XCTAssertEqual(SMCCodec.encodeFloat32(3400), expected)
    }
}
