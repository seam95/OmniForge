import Foundation
import XCTest
@testable import OmniForge

// MARK: - 测试用最小 protobuf 编码器

/// 测试专用 protobuf wire-format 编码器（仅构造已知字段，绝不依赖外部 .proto）。
/// 与 ProtoWireReader 对应，供 Processing/Collector 两个测试文件共用。
enum AntigravityTestProto {
    static func varint(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            var byte = UInt8(truncatingIfNeeded: remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return Data(bytes)
    }

    static func field(_ number: Int, varint value: UInt64) -> Data {
        var data = varint(UInt64((number << 3) | 0))
        data.append(varint(value))
        return data
    }

    static func field(_ number: Int, bytes: Data) -> Data {
        var data = varint(UInt64((number << 3) | 2))
        data.append(varint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    static func field(_ number: Int, string: String) -> Data {
        field(number, bytes: Data(string.utf8))
    }

    /// google.protobuf.Timestamp（#1 秒、#2 纳秒）。
    static func timestamp(seconds: UInt64, nanos: UInt64 = 0) -> Data {
        var data = Data()
        data.append(field(1, varint: seconds))
        data.append(field(2, varint: nanos))
        return data
    }

    /// usage 消息：#1 固定系统 prompt、#2 非缓存输入、#3 输出含 reasoning、
    /// #5 cacheRead、#9 输出净额、#10 reasoning、#11 responseId。
    static func usage(
        fixed: UInt64 = 0,
        input: UInt64 = 0,
        rawOutput: UInt64? = nil,
        cacheRead: UInt64 = 0,
        output: UInt64 = 0,
        reasoning: UInt64 = 0,
        responseID: String? = nil,
        includeZeroFields: Bool = false
    ) -> Data {
        var data = Data()
        func appendVarint(_ number: Int, _ value: UInt64) {
            if value != 0 || includeZeroFields {
                data.append(field(number, varint: value))
            }
        }
        appendVarint(1, fixed)
        appendVarint(2, input)
        if let rawOutput { data.append(field(3, varint: rawOutput)) }
        appendVarint(5, cacheRead)
        appendVarint(9, output)
        appendVarint(10, reasoning)
        if let responseID { data.append(field(11, string: responseID)) }
        return data
    }

    /// chatModel（gen_metadata.data.#1）：#4 usage、#9.#4 旧版时间、#19 responseModel、#21 label。
    static func chatModel(
        usage: Data? = nil,
        responseModel: String? = nil,
        displayLabel: String? = nil,
        legacyTimestamp: (seconds: UInt64, nanos: UInt64)? = nil
    ) -> Data {
        var data = Data()
        if let usage { data.append(field(4, bytes: usage)) }
        if let legacyTimestamp {
            let stamp = AntigravityTestProto.timestamp(
                seconds: legacyTimestamp.seconds,
                nanos: legacyTimestamp.nanos
            )
            data.append(field(9, bytes: field(4, bytes: stamp)))
        }
        if let responseModel { data.append(field(19, string: responseModel)) }
        if let displayLabel { data.append(field(21, string: displayLabel)) }
        return data
    }

    /// gen_metadata.data（外层 #1 = chatModel）。
    static func generation(
        usage: Data? = nil,
        responseModel: String? = nil,
        displayLabel: String? = nil,
        legacyTimestamp: (seconds: UInt64, nanos: UInt64)? = nil
    ) -> Data {
        var data = Data()
        data.append(field(1, bytes: chatModel(
            usage: usage,
            responseModel: responseModel,
            displayLabel: displayLabel,
            legacyTimestamp: legacyTimestamp
        )))
        return data
    }

    /// steps.metadata：#1 Timestamp、#9.#11 responseId、#20.#3 生成序号。
    static func step(
        timestamp: (seconds: UInt64, nanos: UInt64)? = nil,
        responseID: String? = nil,
        generationSequence: Int? = nil
    ) -> Data {
        var data = Data()
        if let timestamp {
            data.append(field(1, bytes: AntigravityTestProto.timestamp(
                seconds: timestamp.seconds,
                nanos: timestamp.nanos
            )))
        }
        if let responseID {
            data.append(field(9, bytes: field(11, string: responseID)))
        }
        if let generationSequence {
            data.append(field(20, bytes: field(3, varint: UInt64(max(0, generationSequence)))))
        }
        return data
    }

    /// trajectory_metadata_blob.data：#1.#1 workspace URI、#2 会话创建 Timestamp。
    static func trajectory(createdAt: (seconds: UInt64, nanos: UInt64), workspaceURI: String? = nil) -> Data {
        var data = Data()
        if let workspaceURI {
            data.append(field(1, bytes: field(1, string: workspaceURI)))
        }
        data.append(field(2, bytes: timestamp(seconds: createdAt.seconds, nanos: createdAt.nanos)))
        return data
    }
}

// MARK: - 处理层测试

/// Antigravity 会话库 protobuf 解析与入桶归一化：
/// 字段解码 / Timestamp / 六列映射 / responseId 去重 / 时间回退链 / 模型恢复 / 坏 blob 容错。
final class AntigravityUsageProcessingTests: XCTestCase {
    /// 本机真实样本（agy 1.1.18+，gen_metadata 第 0 行）的 responseId。
    private let sampleResponseID = "nOHSavOXNcucz7IPlf2gmAs"
    /// 同一真实样本的 steps.#1 Timestamp（epoch 秒 + 纳秒）。
    private let sampleTimestampSeconds: UInt64 = 1_792_205_211
    private let sampleTimestampNanos: UInt64 = 441_479_000
    /// 样本时间所属 UTC 半小时桶起点（1_792_205_211 → 1_792_204_200）。
    private let sampleBucketStart: TimeInterval = 1_792_204_200

    private func sampleUsage() -> Data {
        AntigravityTestProto.usage(
            fixed: 1318,
            input: 14_836,
            cacheRead: 0,
            output: 470,
            reasoning: 91,
            responseID: sampleResponseID
        )
    }

    private func makeGenerations(
        _ generationDatas: [Data],
        steps: [Data] = [],
        trajectory: Data? = nil,
        client: AntigravityClientKind = .cli,
        sessionID: String = "session-1",
        fileModificationDate: Date? = nil
    ) -> [AntigravityGeneration] {
        AntigravityUsageProcessing.makeGenerations(
            generationRows: generationDatas.enumerated().map { (sequence: $0.offset, data: $0.element) },
            stepRows: steps,
            trajectoryData: trajectory,
            client: client,
            sessionID: sessionID,
            fileModificationDate: fileModificationDate
        )
    }

    private func expectedBucket(forSeconds seconds: TimeInterval) -> TimeInterval {
        Double((Int(seconds) / 1800) * 1800)
    }

    // MARK: - ProtoWireReader 基础解码

    func test_protoWireReader_decodesVarintStringsAndNestedMessages() throws {
        var data = Data()
        data.append(AntigravityTestProto.field(1, varint: 16_154))
        data.append(AntigravityTestProto.field(2, string: sampleResponseID))
        data.append(AntigravityTestProto.field(3, bytes: AntigravityTestProto.field(1, varint: sampleTimestampSeconds)))
        data.append(AntigravityTestProto.field(4, bytes: Data()))

        let message = try ProtoMessage(data: data)
        XCTAssertEqual(message.varint(1), 16_154)
        XCTAssertEqual(message.string(2), sampleResponseID)
        XCTAssertEqual(message.message(3)?.varint(1), sampleTimestampSeconds)
        XCTAssertEqual(message.message(4)?.fields.count, 0, "空 length-delimited 是合法空消息")
        XCTAssertNil(message.varint(99))
        XCTAssertNil(message.string(99))
    }

    func test_protoWireReader_truncatedBlobThrows() {
        // 字段 1 声明 5 字节，实际只有 1 字节。
        let truncated = Data([0x0A, 0x05, 0x01])
        XCTAssertThrowsError(try ProtoWireReader.parse(truncated)) { error in
            XCTAssertEqual(error as? ProtoWireReader.DecodingError, .truncated)
        }
    }

    func test_protoMessage_badNestedBytesOnlyDropsThatField() throws {
        var data = AntigravityTestProto.field(1, varint: 7)
        data.append(AntigravityTestProto.field(2, bytes: Data([0x0A, 0xFF])))
        let message = try ProtoMessage(data: data)
        XCTAssertEqual(message.varint(1), 7, "外层字段仍可读")
        XCTAssertNil(message.message(2), "坏嵌套返回 nil，不抛到调用方")
    }

    // MARK: - gen_metadata 解析

    func test_parseGeneration_decodesUsageIdentityModelAndLegacyTimestamp() throws {
        let data = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(
                fixed: 1318,
                input: 14_836,
                cacheRead: 7,
                output: 470,
                reasoning: 91,
                responseID: "resp-1"
            ),
            responseModel: "gemini-3.8-flash",
            displayLabel: "Gemini 3.8 Flash (High)",
            legacyTimestamp: (1_700_000_000, 250_000_000)
        )
        let record = try XCTUnwrap(AntigravityUsageProcessing.parseGeneration(data: data, sequence: 3))

        XCTAssertEqual(record.sequence, 3)
        XCTAssertEqual(record.usage.inputTokens, 16_154, "input = #1 + #2")
        XCTAssertEqual(record.usage.cachedInputTokens, 7)
        XCTAssertEqual(record.usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(record.usage.outputTokens, 470)
        XCTAssertEqual(record.usage.reasoningOutputTokens, 91)
        XCTAssertEqual(record.usage.totalTokens, 16_154 + 470 + 91, "缓存不计入 total")
        XCTAssertTrue(record.hasTokenUsage)
        XCTAssertEqual(record.responseID, "resp-1")
        XCTAssertEqual(record.responseModel, "gemini-3.8-flash")
        XCTAssertEqual(record.displayLabel, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(
            try XCTUnwrap(record.legacyTimestampMilliseconds),
            1_700_000_000_250,
            accuracy: 0.001
        )
    }

    func test_parseGeneration_badBlobReturnsNil() {
        XCTAssertNil(AntigravityUsageProcessing.parseGeneration(data: Data([0xFF, 0x00, 0x13]), sequence: 0))
        XCTAssertNil(AntigravityUsageProcessing.parseGeneration(data: Data(), sequence: 0), "空 blob 无 chatModel")
    }

    // MARK: - 六列映射

    func test_tokenUsage_mapsSixColumnsAndIgnoresRawOutputTotal() throws {
        // #3 = 输出含 reasoning（= 50）；归一化只取 #9（净输出 30）与 #10（reasoning 20）。
        let data = AntigravityTestProto.usage(
            fixed: 100,
            input: 200,
            rawOutput: 50,
            cacheRead: 40,
            output: 30,
            reasoning: 20,
            responseID: "r"
        )
        let message = try ProtoMessage(data: data)
        let usage = AntigravityUsageProcessing.tokenUsage(from: message)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.cachedInputTokens, 40)
        XCTAssertEqual(usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 30, "output 取 #9 净额，不取 #3 含 reasoning 值")
        XCTAssertEqual(usage.reasoningOutputTokens, 20)
        XCTAssertEqual(usage.totalTokens, 300 + 30 + 20)
    }

    func test_tokenUsage_missingUsageMessageIsZero() {
        XCTAssertEqual(AntigravityUsageProcessing.tokenUsage(from: nil), .zero)
    }

    // MARK: - Timestamp / 桶

    func test_timestampMilliseconds_convertsSecondsAndNanos() throws {
        let message = try ProtoMessage(
            data: AntigravityTestProto.timestamp(seconds: sampleTimestampSeconds, nanos: sampleTimestampNanos)
        )
        let milliseconds = try XCTUnwrap(AntigravityUsageProcessing.timestampMilliseconds(message))
        XCTAssertEqual(milliseconds, 1_792_205_211_441.479, accuracy: 0.001)
    }

    func test_timestampMilliseconds_zeroOrInvalidSecondsReturnsNil() throws {
        let zero = try ProtoMessage(data: AntigravityTestProto.timestamp(seconds: 0, nanos: 0))
        XCTAssertNil(AntigravityUsageProcessing.timestampMilliseconds(zero))
        XCTAssertNil(AntigravityUsageProcessing.timestampMilliseconds(ProtoMessage(fields: [])))
    }

    func test_bucketStart_floorsToUtcHalfHour() throws {
        let bucket = try XCTUnwrap(
            AntigravityUsageProcessing.bucketStart(fromMilliseconds: 1_792_205_211_441.479)
        )
        XCTAssertEqual(bucket.timeIntervalSince1970, sampleBucketStart)
        XCTAssertEqual(bucket.timeIntervalSince1970.truncatingRemainder(dividingBy: 1800), 0)
        XCTAssertNil(AntigravityUsageProcessing.bucketStart(fromMilliseconds: 0))
        XCTAssertNil(AntigravityUsageProcessing.bucketStart(fromMilliseconds: .nan))
    }

    // MARK: - 端到端样本（本机真实数据）

    func test_makeGenerations_matchesKnownRealSample() throws {
        let generation = AntigravityTestProto.generation(
            usage: sampleUsage(),
            responseModel: "gemini-3.8-flash"
        )
        let step = AntigravityTestProto.step(
            timestamp: (sampleTimestampSeconds, sampleTimestampNanos),
            responseID: sampleResponseID,
            generationSequence: 0
        )
        let trajectory = AntigravityTestProto.trajectory(createdAt: (1_792_200_000, 0))

        let result = makeGenerations(
            [generation],
            steps: [step],
            trajectory: trajectory,
            sessionID: "768db432-1cb8-4c46-9f50-b8f79a1f59d2"
        )
        let item = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(item.usage.inputTokens, 16_154)
        XCTAssertEqual(item.usage.cachedInputTokens, 0)
        XCTAssertEqual(item.usage.outputTokens, 470)
        XCTAssertEqual(item.usage.reasoningOutputTokens, 91)
        XCTAssertEqual(item.usage.totalTokens, 16_715)
        XCTAssertEqual(item.model, "gemini-3.8-flash")
        XCTAssertEqual(item.bucketStart.timeIntervalSince1970, sampleBucketStart)
        XCTAssertEqual(
            item.deduplicationKey,
            "antigravity:cli:768db432-1cb8-4c46-9f50-b8f79a1f59d2:\(sampleResponseID)"
        )
        XCTAssertEqual(item.conversationDelta, 1, "每条有效生成计 1 次会话")
    }

    // MARK: - 零用量与去重

    func test_makeGenerations_skipsAllZeroUsageButKeepsInputOnly() {
        let zero = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(includeZeroFields: true),
            responseModel: "gemini-3.8-flash"
        )
        let inputOnly = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 1298),
            responseModel: "gemini-3.7-flash-control"
        )
        let result = makeGenerations(
            [zero, inputOnly],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.count, 1, "四者全零跳过；仅固定输入非零仍计")
        XCTAssertEqual(result.first?.usage.inputTokens, 1298)
        XCTAssertEqual(result.first?.usage.totalTokens, 1298)
    }

    func test_makeGenerations_dedupesSameResponseIDWithinDatabase() {
        let first = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 100, output: 10, responseID: "dup-id")
        )
        let second = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 999, output: 99, responseID: "dup-id")
        )
        let result = makeGenerations(
            [first, second],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.count, 1, "同一 DB 内 responseId 重复只计一次")
        XCTAssertEqual(result.first?.usage.inputTokens, 100, "保留首条")
        XCTAssertEqual(result.first?.deduplicationKey, "antigravity:cli:session-1:dup-id")
    }

    func test_makeGenerations_usesSequenceKeyWhenResponseIDMissing() {
        let data = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 1298))
        let result = makeGenerations(
            [data],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.first?.deduplicationKey, "antigravity:cli:session-1:seq:0")
    }

    func test_makeGenerations_ideClientPrefixDiffersFromCLI() {
        let data = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 1, responseID: "r1")
        )
        let result = makeGenerations(
            [data],
            client: .ide,
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.first?.deduplicationKey, "antigravity:ide:session-1:r1")
    }

    // MARK: - 时间回退链

    func test_timeFallback_legacyTimestampWinsOverStepsAndTrajectory() throws {
        let generation = AntigravityTestProto.generation(
            usage: sampleUsage(),
            legacyTimestamp: (1_700_000_000, 500_000_000)
        )
        let step = AntigravityTestProto.step(
            timestamp: (sampleTimestampSeconds, sampleTimestampNanos),
            responseID: sampleResponseID
        )
        let trajectory = AntigravityTestProto.trajectory(createdAt: (1_792_500_000, 0))
        let result = makeGenerations([generation], steps: [step], trajectory: trajectory)
        XCTAssertEqual(
            result.first?.bucketStart.timeIntervalSince1970,
            expectedBucket(forSeconds: 1_700_000_000.5),
            "旧版 chatModel.#9.#4 优先级最高"
        )
    }

    func test_timeFallback_stepsByResponseID() throws {
        let generation = AntigravityTestProto.generation(usage: sampleUsage())
        let mismatchedStep = AntigravityTestProto.step(
            timestamp: (1_600_000_000, 0),
            responseID: "other-id"
        )
        let matchedStep = AntigravityTestProto.step(
            timestamp: (sampleTimestampSeconds, sampleTimestampNanos),
            responseID: sampleResponseID,
            generationSequence: 0
        )
        let trajectory = AntigravityTestProto.trajectory(createdAt: (1_792_500_000, 0))
        let result = makeGenerations(
            [generation],
            steps: [mismatchedStep, matchedStep],
            trajectory: trajectory
        )
        XCTAssertEqual(result.first?.bucketStart.timeIntervalSince1970, sampleBucketStart)
    }

    func test_timeFallback_stepsByGenerationSequence() throws {
        // 无 responseId 的生成：用 steps.#20.#3 的生成序号匹配。
        let first = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 10))
        let second = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 20))
        let stepZero = AntigravityTestProto.step(timestamp: (1_700_000_000, 0), generationSequence: 0)
        let stepOne = AntigravityTestProto.step(timestamp: (1_700_003_600, 0), generationSequence: 1)
        let result = makeGenerations([first, second], steps: [stepZero, stepOne])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].bucketStart.timeIntervalSince1970, expectedBucket(forSeconds: 1_700_000_000))
        XCTAssertEqual(result[1].bucketStart.timeIntervalSince1970, expectedBucket(forSeconds: 1_700_003_600))
    }

    func test_timeFallback_conversationCreationWhenStepsMissing() throws {
        let generation = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10, responseID: sampleResponseID)
        )
        let unmatchedStep = AntigravityTestProto.step(timestamp: (1_600_000_000, 0), responseID: "other-id")
        let trajectory = AntigravityTestProto.trajectory(createdAt: (1_792_500_000, 0))
        let result = makeGenerations(
            [generation],
            steps: [unmatchedStep],
            trajectory: trajectory,
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            result.first?.bucketStart.timeIntervalSince1970,
            expectedBucket(forSeconds: 1_792_500_000),
            "会话创建时间优先于文件 mtime"
        )
    }

    func test_timeFallback_fileModificationWhenNoOtherSource() throws {
        let generation = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 10))
        let result = makeGenerations(
            [generation],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            result.first?.bucketStart.timeIntervalSince1970,
            expectedBucket(forSeconds: 1_700_000_000),
            "最后一级回退到文件 mtime"
        )
    }

    // MARK: - 模型恢复

    func test_modelRecovery_usesDirectResponseModel() {
        let data = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            responseModel: "gemini-3.8-flash"
        )
        let result = makeGenerations([data], fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.first?.model, "gemini-3.8-flash")
    }

    func test_modelRecovery_routeLabelFallsBackToLabelMapping() {
        let routeRow = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            responseModel: "gemini-default",
            displayLabel: "Gemini 3.7 Flash (High)"
        )
        let modelRow = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 20),
            responseModel: "gemini-3.7-flash",
            displayLabel: "Gemini 3.7 Flash (High)"
        )
        let result = makeGenerations(
            [routeRow, modelRow],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].model, "gemini-3.7-flash", "路由标签不当作模型，走同文件 label 映射")
        XCTAssertEqual(result[1].model, "gemini-3.7-flash")
    }

    func test_modelRecovery_labelMappingWinsOverFileUniqueModel() {
        let labelOnly = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            displayLabel: "Label A"
        )
        let modelA = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 20),
            responseModel: "gemini-x",
            displayLabel: "Label A"
        )
        let modelB = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 30),
            responseModel: "gemini-y",
            displayLabel: "Label B"
        )
        let result = makeGenerations(
            [labelOnly, modelA, modelB],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result[0].model, "gemini-x", "同文件 label 到 #19 唯一映射优先于文件唯一模型")
    }

    func test_modelRecovery_ambiguousLabelIsDropped() {
        let labelOnly = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            displayLabel: "Mystery Label"
        )
        let modelA = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 20),
            responseModel: "model-a",
            displayLabel: "Mystery Label"
        )
        let modelB = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 30),
            responseModel: "model-b",
            displayLabel: "Mystery Label"
        )
        let result = makeGenerations(
            [labelOnly, modelA, modelB],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result[0].model, "unknown", "同 label 对应两个 #19 → 歧义丢弃，且文件非唯一模型")
    }

    func test_modelRecovery_knownDisplayNameMapping() {
        let data = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            displayLabel: "Gemini 3.5 Flash (High)"
        )
        let result = makeGenerations([data], fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.first?.model, "gemini-3.5-flash-high")
    }

    func test_modelRecovery_knownDisplayNameMappingLowUsesExtraLow() {
        let data = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            displayLabel: "Gemini 3.5 Flash (Low)"
        )
        let result = makeGenerations([data], fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.first?.model, "gemini-3.5-flash-extra-low")
    }

    func test_modelRecovery_fileUniqueResponseModel() {
        let labelOnly = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 10))
        let modeled = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 20),
            responseModel: "gemini-3.8-flash"
        )
        let result = makeGenerations(
            [labelOnly, modeled],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result[0].model, "gemini-3.8-flash", "文件内唯一 #19 兜底")
    }

    func test_modelRecovery_uniqueFallbackRequiresRecognizedLabels() {
        let unknownLabel = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 10),
            displayLabel: "Mystery Model"
        )
        let modeled = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 20),
            responseModel: "gemini-3.8-flash"
        )
        let result = makeGenerations(
            [unknownLabel, modeled],
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result[0].model, "unknown", "存在无法识别的 label → 不套用文件唯一 #19")
        XCTAssertEqual(result[1].model, "gemini-3.8-flash")
    }

    func test_modelRecovery_unknownWhenNoSignal() {
        let data = AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 10))
        let result = makeGenerations([data], fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.first?.model, AntigravityUsageProcessing.defaultModel)
        XCTAssertEqual(AntigravityUsageProcessing.defaultModel, "unknown")
    }

    func test_usableResponseModel_filtersRouteLabelAndTrims() {
        XCTAssertNil(AntigravityUsageProcessing.usableResponseModel("  gemini-default "))
        XCTAssertNil(AntigravityUsageProcessing.usableResponseModel("   "))
        XCTAssertNil(AntigravityUsageProcessing.usableResponseModel(nil))
        XCTAssertEqual(
            AntigravityUsageProcessing.usableResponseModel("  gemini-3.8-flash  "),
            "gemini-3.8-flash"
        )
    }

    // MARK: - 坏 blob 容错

    func test_makeGenerations_skipsBadBlobsWithoutCrash() throws {
        let good = AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: 100, responseID: "good"),
            responseModel: "gemini-3.8-flash"
        )
        let badGeneration = Data([0xFF, 0x00, 0x13, 0x37])
        let badStep = Data([0x0A, 0xFF])
        let badTrajectory = Data([0x12, 0xFF])
        let result = makeGenerations(
            [badGeneration, good, badGeneration],
            steps: [badStep],
            trajectory: badTrajectory,
            fileModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(result.count, 1, "坏 blob 逐行跳过，好行仍入桶")
        XCTAssertEqual(result.first?.usage.inputTokens, 100)
        XCTAssertEqual(result.first?.model, "gemini-3.8-flash")
    }

    func test_makeGenerations_emptyGenerationRowsReturnsEmpty() {
        XCTAssertTrue(makeGenerations([]).isEmpty)
    }
}
