import Foundation
import IOKit

/// SMC 访问错误 — 读路径与诊断使用
public enum SMCError: Error, LocalizedError {
    case driverNotFound
    case connectionClosed
    case keyNotFound(String)
    case readFailed(kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .driverNotFound: return "AppleSMC driver not found"
        case .connectionClosed: return "SMC connection is closed"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .readFailed(let code): return "SMC read failed with code: \(code)"
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
