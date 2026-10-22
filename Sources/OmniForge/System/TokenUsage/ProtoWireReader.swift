import Foundation

// MARK: - 极简 protobuf wire-format 读取器

/// Antigravity 用量采集专用 protobuf wire-format 读取器（手写，零依赖）。
///
/// 背景：Antigravity 的 `gen_metadata.data` / `steps.metadata` /
/// `trajectory_metadata_blob.data` 都是未公开 .proto 的 protobuf blob，
/// 只能按**字段号**取值（字段语义见 `AntigravityUsageProcessing`）。
///
/// 隐私红线（SPEC 2.6）：blob 内混有对话正文。本读取器只把字节切成字段，
/// **不解释、不打印、不落盘**；上层只按已知字段号取数值/时间/模型/responseId。
///
/// 支持的 wire type：varint(0)、fixed64(1)、length-delimited(2)、fixed32(5)。
/// 已废弃的 group(3/4) 与非法字段号直接抛错，由调用方按「坏 blob」跳过该行/该库。
enum ProtoWireReader {
    /// protobuf wire type。
    enum WireType: UInt8, Equatable {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// 单个已解码字段。只有与 `wireType` 对应的值有效：
    /// - `.varint` → `varintValue`；
    /// - `.lengthDelimited` → `bytes`（字符串/嵌套消息的原始字节）；
    /// - `.fixed64` / `.fixed32` → `varintValue` 承载定长值（小端）。
    struct Field: Equatable {
        var number: Int
        var wireType: WireType
        var varintValue: UInt64
        var bytes: [UInt8]
    }

    /// 解码错误（坏 blob / 截断 / 非法字段号）。
    enum DecodingError: Error, Equatable {
        /// 数据在字段中途结束。
        case truncated
        /// 字段号为 0 或超出 protobuf 上限（2^29 - 1）。
        case invalidFieldNumber(Int)
        /// 未知 wire type（含已废弃的 group 3/4）。
        case unsupportedWireType(UInt8)
        /// varint 超过 64 位上限。
        case varintTooLong
    }

    /// protobuf 字段号上限（2^29 - 1）。
    static let maximumFieldNumber = 536_870_911

    /// 解析一段 protobuf 消息为字段列表（保持出现顺序，重复字段保留多项）。
    static func parse(_ data: Data) throws -> [Field] {
        try parse(Array(data))
    }

    /// 解析字节数组版本的 protobuf 消息。
    static func parse(_ bytes: [UInt8]) throws -> [Field] {
        var fields: [Field] = []
        var index = 0
        while index < bytes.count {
            let key = try readVarint(bytes, index: &index)
            let number = Int(key >> 3)
            guard number >= 1, number <= maximumFieldNumber else {
                throw DecodingError.invalidFieldNumber(number)
            }
            let rawWireType = UInt8(key & 0x07)
            guard let wireType = WireType(rawValue: rawWireType) else {
                throw DecodingError.unsupportedWireType(rawWireType)
            }
            switch wireType {
            case .varint:
                let value = try readVarint(bytes, index: &index)
                fields.append(Field(number: number, wireType: .varint, varintValue: value, bytes: []))
            case .fixed64:
                guard index + 8 <= bytes.count else { throw DecodingError.truncated }
                var value: UInt64 = 0
                for offset in 0..<8 {
                    value |= UInt64(bytes[index + offset]) << (8 * offset)
                }
                index += 8
                fields.append(Field(number: number, wireType: .fixed64, varintValue: value, bytes: []))
            case .lengthDelimited:
                let length = try readVarint(bytes, index: &index)
                // 先比较再转 Int，避免超大长度值触发 Int 转换陷阱。
                guard length <= UInt64(bytes.count - index) else { throw DecodingError.truncated }
                let end = index + Int(length)
                fields.append(Field(
                    number: number,
                    wireType: .lengthDelimited,
                    varintValue: 0,
                    bytes: Array(bytes[index..<end])
                ))
                index = end
            case .fixed32:
                guard index + 4 <= bytes.count else { throw DecodingError.truncated }
                var value: UInt64 = 0
                for offset in 0..<4 {
                    value |= UInt64(bytes[index + offset]) << (8 * offset)
                }
                index += 4
                fields.append(Field(number: number, wireType: .fixed32, varintValue: value, bytes: []))
            }
        }
        return fields
    }

    /// 读取 varint（最多 10 字节）；越界/超长抛错。
    private static func readVarint(_ bytes: [UInt8], index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw DecodingError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw DecodingError.varintTooLong }
        }
    }
}

// MARK: - 按字段号取值

/// 已解码的 protobuf 消息（字段列表 + 字段号快捷取值）。
///
/// 嵌套消息按 length-delimited 字节递归解析；坏嵌套返回 nil（视为该字段缺失），
/// 保证单行坏字段只丢该字段、不让整个库文件失败。
struct ProtoMessage {
    let fields: [ProtoWireReader.Field]

    /// 从原始字节解码；损坏时抛错。
    init(data: Data) throws {
        self.fields = try ProtoWireReader.parse(data)
    }

    /// 从已解码字段创建（嵌套消息 / 测试用）。
    init(fields: [ProtoWireReader.Field]) {
        self.fields = fields
    }

    /// 首个指定字段号的 varint 值（wire type 必须匹配）。
    func varint(_ number: Int) -> UInt64? {
        fields.first { $0.number == number && $0.wireType == .varint }?.varintValue
    }

    /// 首个指定字段号的 length-delimited 原始字节。
    func bytes(_ number: Int) -> [UInt8]? {
        fields.first { $0.number == number && $0.wireType == .lengthDelimited }?.bytes
    }

    /// 首个指定字段号的 UTF-8 字符串（非法 UTF-8 → nil）。
    func string(_ number: Int) -> String? {
        guard let bytes = bytes(number) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// 首个指定字段号的嵌套消息；坏嵌套/缺字段 → nil。
    func message(_ number: Int) -> ProtoMessage? {
        guard let bytes = bytes(number) else { return nil }
        guard let fields = try? ProtoWireReader.parse(bytes) else { return nil }
        return ProtoMessage(fields: fields)
    }

}
