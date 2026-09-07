import Foundation

/// SMC key 枚举边界 — 传感器发现使用，SMCClient 实现生产路径
public protocol SMCKeyEnumerating: AnyObject {
    func totalKeyCount() -> Int?
    func keyName(at index: Int) -> String?
}

/// 风扇写入序列的底层命令边界 — SMCClient 实现生产路径，测试注入替身记录调用序
public protocol FanSMCCommanding: AnyObject {
    /// 单字节 key 读取（FNum 计数 / F{i}Md 模式）
    func readUInt8(forKey name: String) -> UInt8?
    /// 双字节无符号 key 读取（FS! 位掩码）
    func readUInt16(forKey name: String) -> UInt16?
    /// 数值 key 读取（F{i}Ac/Mn/Mx/Tg，flt/fpe2 解码）
    func readDouble(forKey name: String) -> Double?
    /// key 数据宽度（决定转速写入编码：2 字节 fpe2 / 4 字节 float32）
    func dataSize(forKey name: String) -> UInt32?
    /// 写 key
    func write(bytes: [UInt8], forKey name: String) throws
}

/// 风扇手动控制写入序列。
/// Apple Silicon：首个写入前开启 SMC 测试模式接管风扇（Ftst=1），全部风扇归还
/// 自动后关闭；Intel：通过 FS! 位掩码置位/复位。
/// testModeActive 状态要求持有方保持单一长生命周期实例（特权 Helper 内复用）。
public final class FanSMCWriter {
    private let smc: FanSMCCommanding
    private var testModeActive = false

    public init(smc: FanSMCCommanding) {
        self.smc = smc
    }

    public func fanCount() -> Int? {
        guard let raw = smc.readUInt8(forKey: SMCFanKey.fanCount) else { return nil }
        return Int(raw)
    }

    public func isManualMode(index: Int) -> Bool? {
        guard let raw = smc.readUInt8(forKey: SMCFanKey.mode(index)) else { return nil }
        return raw != 0
    }

    /// 将风扇设为手动并写入目标转速。转速做防御性钳制（特权写入边界的最后防线）。
    public func setFanSpeed(index: Int, rpm: Double) throws {
        #if arch(arm64)
        try enableTestModeIfNeeded()
        try smc.write(bytes: [1], forKey: SMCFanKey.mode(index))
        #else
        try setForceModeBit(index: index, forced: true)
        #endif
        try writeTargetSpeed(index: index, rpm: min(max(rpm, 100), 20000))
    }

    /// 单风扇归还自动；确认再无手动风扇后关闭测试模式
    public func setFanAuto(index: Int) throws {
        #if arch(arm64)
        try smc.write(bytes: [0], forKey: SMCFanKey.mode(index))
        if !anyFanManual() {
            try disableTestMode()
        }
        #else
        try setForceModeBit(index: index, forced: false)
        #endif
    }

    /// 全部风扇归还自动并退出测试模式（性能模式关闭/系统睡眠的唯一归还路径）
    public func resetAllFansToAuto() throws {
        let count = fanCount() ?? 0
        for index in 0..<count {
            #if arch(arm64)
            try smc.write(bytes: [0], forKey: SMCFanKey.mode(index))
            #else
            try setForceModeBit(index: index, forced: false)
            #endif
        }
        #if arch(arm64)
        try disableTestMode()
        #endif
    }

    // MARK: - 内部

    private func writeTargetSpeed(index: Int, rpm: Double) throws {
        let key = SMCFanKey.targetSpeed(index)
        let bytes: [UInt8]
        if smc.dataSize(forKey: key) == 2 {
            bytes = SMCCodec.encodeFPE2(rpm)
        } else {
            bytes = SMCCodec.encodeFloat32(rpm)
        }
        try smc.write(bytes: bytes, forKey: key)
    }

    #if arch(arm64)
    private func enableTestModeIfNeeded() throws {
        guard !testModeActive else { return }
        try smc.write(bytes: [1], forKey: SMCFanKey.testMode)
        testModeActive = true
    }

    private func disableTestMode() throws {
        guard testModeActive else { return }
        try smc.write(bytes: [0], forKey: SMCFanKey.testMode)
        testModeActive = false
    }

    private func anyFanManual() -> Bool {
        guard let count = fanCount() else { return testModeActive }
        for index in 0..<count {
            if let manual = isManualMode(index: index), manual { return true }
        }
        return false
    }
    #else
    private func setForceModeBit(index: Int, forced: Bool) throws {
        guard let current = smc.readUInt16(forKey: SMCFanKey.forceMode) else {
            throw SMCError.keyNotFound(SMCFanKey.forceMode)
        }
        let bit = UInt16(1 << index)
        let mask = forced ? (current | bit) : (current & ~bit)
        try smc.write(bytes: [UInt8(mask >> 8), UInt8(mask & 0xFF)], forKey: SMCFanKey.forceMode)
    }
    #endif
}
