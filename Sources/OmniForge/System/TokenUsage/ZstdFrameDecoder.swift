import Foundation
import libzstd

/// zstd 帧增量解压 — DSH 会话日志专用。
///
/// DSH 每次 flush 追加一个独立的 zstd frame，日志是多帧拼接而不是单帧流。
/// 活动会话正在写入时，尾帧可能是 torn（半个帧），因此本解码器：
/// - 只解压完整帧，尾部的 torn 数据不消费，留给下一轮重读；
/// - 返回 consumed = 最后一个完整帧结束的字节偏移，供采集器推进游标；
/// - 遇到坏帧时保留已解压前缀并标记 stoppedOnError，不整体丢弃会话。
///
/// 上限：单次读取 64 MiB、解压 64 MiB，防压缩炸弹与异常大文件拖垮扫描。
enum ZstdFrameDecoder {
    static let maxCompressedBytes = 64 * 1024 * 1024
    static let maxDecodedBytes = 64 * 1024 * 1024

    /// 单次增量解码结果。
    struct Result: Equatable {
        var text: String
        /// 已消费到的压缩字节偏移（最后一个完整帧的 end）。
        var consumed: Int
        /// 是否在坏帧处停止（text/consumed 仍是可信前缀）。
        var stoppedOnError: Bool
    }

    /// zstd 帧在 buffer 中的字节范围。
    struct Frame: Equatable {
        var start: Int
        var end: Int
    }

    /// 解码 data 中的完整帧；尾部的 torn 帧不消费。
    static func decodeIncrement(_ data: Data, maxDecodedBytes: Int = maxDecodedBytes) -> Result {
        let frames = scanFrames(data)
        guard !frames.isEmpty else {
            return Result(text: "", consumed: 0, stoppedOnError: false)
        }
        var text = ""
        var consumed = 0
        for frame in frames {
            let frameData = data.subdata(in: frame.start..<frame.end)
            let remaining = maxDecodedBytes - text.utf8.count
            guard remaining > 0, let decoded = decompressFrame(frameData, capacity: remaining) else {
                return Result(text: text, consumed: consumed, stoppedOnError: true)
            }
            text += decoded
            consumed = frame.end
        }
        return Result(text: text, consumed: consumed, stoppedOnError: false)
    }

    // MARK: - 帧边界扫描（RFC 8478）

    /// 不依赖解压地定位完整帧边界；遇到 torn/非法尾帧即停止。
    static func scanFrames(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        var offset = 0
        let count = data.count
        while offset < count {
            guard count - offset >= 4,
                  data[offset] == 0x28, data[offset + 1] == 0xB5,
                  data[offset + 2] == 0x2F, data[offset + 3] == 0xFD else {
                break
            }
            let start = offset
            offset += 4
            guard offset < count else { break }
            let descriptor = data[offset]
            offset += 1
            // 保留位必须为 0；否则视为 torn/非法尾部。
            guard descriptor & 0x18 == 0 else { return frames }
            let singleSegment = descriptor & 0x20 != 0
            let checksum = descriptor & 0x04 != 0
            let dictionaryFlag = descriptor & 0x03
            let dictionaryBytes = dictionaryFlag == 3 ? 4 : Int(dictionaryFlag)
            let contentSizeFlag = descriptor >> 6
            let contentSizeBytes: Int
            if contentSizeFlag == 0 {
                contentSizeBytes = singleSegment ? 1 : 0
            } else {
                contentSizeBytes = 1 << Int(contentSizeFlag)
            }
            // window descriptor 仅非 single-segment 帧存在。
            offset += (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes
            guard offset <= count else { return frames }

            var lastBlock = false
            while !lastBlock {
                guard count - offset >= 3 else { return frames }
                let header = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                offset += 3
                lastBlock = header & 1 != 0
                let blockType = (header >> 1) & 0x03
                guard blockType != 0x03 else { return frames } // 保留块类型：坏帧
                let payloadBytes = blockType == 0x01 ? 1 : Int(header >> 3)
                offset += payloadBytes
                guard offset <= count else { return frames }
            }
            if checksum {
                offset += 4
                guard offset <= count else { return frames }
            }
            frames.append(Frame(start: start, end: offset))
        }
        return frames
    }

    // MARK: - 单帧解压

    /// 用 libzstd 流式 API 解压一个完整帧；失败返回 nil。
    private static func decompressFrame(_ frame: Data, capacity: Int) -> String? {
        guard !frame.isEmpty, capacity > 0 else { return nil }
        guard let dstream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(dstream) }
        ZSTD_initDStream(dstream)

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        let ok: Bool = frame.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return false }
            var input = ZSTD_inBuffer(src: src, size: raw.count, pos: 0)
            while true {
                var stepFailed = false
                var frameFinished = false
                chunk.withUnsafeMutableBytes { dst in
                    guard let dstBase = dst.baseAddress else {
                        stepFailed = true
                        return
                    }
                    var out = ZSTD_outBuffer(dst: dstBase, size: dst.count, pos: 0)
                    let result = ZSTD_decompressStream(dstream, &out, &input)
                    if ZSTD_isError(result) != 0 {
                        stepFailed = true
                        return
                    }
                    if out.pos > 0 {
                        output.append(
                            contentsOf: UnsafeRawBufferPointer(start: dstBase, count: out.pos)
                                .bindMemory(to: UInt8.self)
                        )
                    }
                    frameFinished = result == 0
                }
                if stepFailed { return false }
                if output.count > capacity { return false }
                if frameFinished { break }
                // 输入耗尽但帧未结束：说明帧边界判断有误，保守失败。
                if input.pos >= input.size { return false }
            }
            return true
        }

        guard ok else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
