import Foundation
import IOKit

/// SMC 访问错误 — 写路径与诊断使用
public enum SMCError: Error, LocalizedError {
    case driverNotFound
    case connectionClosed
    case keyNotFound(String)
    case readFailed(kern_return_t)
    case writeFailed(kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .driverNotFound: return "AppleSMC driver not found"
        case .connectionClosed: return "SMC connection is closed"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .readFailed(let code): return "SMC read failed with code: \(code)"
        case .writeFailed(let code): return "SMC write failed with code: \(code)"
        }
    }
}

public final class SMCClient: SMCReading {
    public struct Key {
        public let code: UInt32
        public let name: String
        public let dataSize: UInt32
        public let dataType: String
    }

    private var connection: io_connect_t = 0
    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdWriteKey: UInt8 = 6
    private static let cmdKeyFromIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    /// key 元信息缓存 — 避免每次读取重复走 getKeyInfo 调用。
    /// 实例约定由调用方串行使用（现有采样器均在各自队列内独占实例），不加锁。
    private var keyInfoCache: [UInt32: Key] = [:]

    public init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    public var isConnected: Bool { connection != 0 }

    public func value(forKey keyName: String) -> Double? {
        guard let smcKey = key(named: keyName) else { return nil }
        return self.readValue(smcKey)
    }

    public func key(named name: String) -> Key? {
        if let cached = keyInfoCache[Self.fourCC(name)] { return cached }
        var probe = SMCParamStruct()
        probe.key = Self.fourCC(name)
        probe.data8 = Self.cmdKeyInfo
        guard let out = call(&probe), out.result == 0 else { return nil }
        let key = Key(code: probe.key, name: name,
                      dataSize: out.keyInfo.dataSize,
                      dataType: Self.fourCCString(out.keyInfo.dataType))
        keyInfoCache[key.code] = key
        return key
    }

    public func readValue(_ key: Key) -> Double? {
        guard let out = readRaw(key) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(key.dataSize))) }
        switch key.dataType {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.load(as: Float32.self) })
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "ioft" where bytes.count == 8:
            return Double(bytes.withUnsafeBytes { $0.load(as: UInt64.self) }) / 65536.0
        case "fpe2" where bytes.count >= 2:
            // 无符号 14.2 定点：高位在前，低 2 位为小数
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        case "ui8 ", "flag" where !bytes.isEmpty:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        default: return nil
        }
    }

    // MARK: - 原始读写与 key 枚举（风扇控制与传感器发现使用）

    /// 读取 key 的原始字节（截断到 dataSize）
    public func readBytes(forKey name: String) -> [UInt8]? {
        guard let key = key(named: name), let out = readRaw(key) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(key.dataSize))) }
    }

    /// 单字节 key（ui8/flag）读取；字节缺失或 key 不存在返回 nil
    public func readUInt8(forKey name: String) -> UInt8? {
        readBytes(forKey: name)?.first
    }

    /// 写 key。写入长度必须与 key 的 dataSize 一致，否则 SMC 拒绝。
    public func write(bytes: [UInt8], forKey name: String) throws {
        guard connection != 0 else { throw SMCError.connectionClosed }
        guard let key = key(named: name) else { throw SMCError.keyNotFound(name) }

        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = Self.cmdWriteKey
        input.keyInfo.dataSize = key.dataSize
        input.keyInfo.dataType = Self.fourCC(key.dataType)

        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (offset, byte) in bytes.prefix(32).enumerated() {
                raw.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
            }
        }

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        guard kr == kIOReturnSuccess else { throw SMCError.writeFailed(kr) }
    }

    /// SMC key 总数（"#KEY"，固定 ui32/4 字节），供传感器发现枚举使用
    public func totalKeyCount() -> Int? {
        // #KEY 是 SMC 标准 key，直接按固定布局构造，不写入 keyInfo 缓存
        let countKey = Key(code: Self.fourCC("#KEY"), name: "#KEY", dataSize: 4, dataType: "ui32")
        guard let out = readRaw(countKey) else { return nil }
        let b = out.bytes
        return Int((UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3))
    }

    /// 按索引枚举 key 名，供传感器发现使用
    public func keyName(at index: Int) -> String? {
        guard connection != 0 else { return nil }
        var input = SMCParamStruct()
        input.data32 = UInt32(index)
        input.data8 = Self.cmdKeyFromIndex
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }
        return Self.fourCCString(output.key)
    }

    // MARK: - 内部

    private func readRaw(_ key: Key) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.dataSize
        input.data8 = Self.cmdReadKey
        return call(&input)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        return kr == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let chars: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                              UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
}

// MARK: - 风扇写入命令边界实现

extension SMCClient: FanSMCCommanding, SMCKeyEnumerating {
    /// 双字节无符号 key（大端）读取；FS! 位掩码使用
    public func readUInt16(forKey name: String) -> UInt16? {
        guard let bytes = readBytes(forKey: name), bytes.count >= 2 else { return nil }
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    /// 数值 key 读取（flt/fpe2/sp78 等按 dataType 解码）
    public func readDouble(forKey name: String) -> Double? {
        value(forKey: name)
    }

    /// key 数据宽度，决定转速写入编码
    public func dataSize(forKey name: String) -> UInt32? {
        key(named: name)?.dataSize
    }
}
