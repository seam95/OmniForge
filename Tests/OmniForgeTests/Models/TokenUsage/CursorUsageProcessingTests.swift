import Foundation
import XCTest
@testable import OmniForge

/// Cursor 云端账单 CSV 解析（export-usage-events-csv?strategy=tokens，参考 08）。
///
/// 列序随 Cursor 随时插列（Cloud Agent ID / Automation ID 等），一律按表头名解析列；
/// 只解析 token 计数字段与日期/模型；Cost 等计费字段从不读取落库（隐私红线，SPEC 2.6）。
final class CursorUsageProcessingTests: XCTestCase {

    // MARK: - 表头名解析（列序变化免疫）

    func test_parseCSV_newestFormat_withCloudAgentColumns() {
        let csv = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-04-16T03:32:33.284Z","","","On-Demand","composer-2-fast","No","0","3189","194368","1815","199372","0.11"
        "2026-04-15T03:39:53.013Z","","","On-Demand","auto","No","0","132586","93728","2303","228617","0.20"
        """
        let rows = CursorUsageProcessing.parseCSV(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "composer-2-fast")
        XCTAssertEqual(rows[0].kind, "On-Demand")
        XCTAssertEqual(rows[0].inputWithoutCache, 3_189)
        XCTAssertEqual(rows[0].cacheWrite, 0, "Input(with Cache Write) - Input(without) = cache 写")
        XCTAssertEqual(rows[0].cacheRead, 194_368)
        XCTAssertEqual(rows[0].outputTokens, 1_815)
        XCTAssertEqual(rows[1].model, "auto")
    }

    func test_parseCSV_newFormat_mapsAllFields() {
        let csv = """
        Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-03-20T06:56:12.521Z","Included","composer-2-fast","No","160000","159990","578207","2055","740252","0.49"
        """
        let row = try! XCTUnwrap(CursorUsageProcessing.parseCSV(csv).first)
        XCTAssertEqual(row.kind, "Included")
        XCTAssertEqual(row.model, "composer-2-fast")
        XCTAssertEqual(row.maxMode, "No")
        XCTAssertEqual(row.inputWithoutCache, 159_990)
        XCTAssertEqual(row.cacheWrite, 10, "160000 - 159990")
        XCTAssertEqual(row.cacheRead, 578_207)
        XCTAssertEqual(row.outputTokens, 2_055)
        XCTAssertEqual(row.totalTokens, 740_252)
    }

    func test_parseCSV_oldFormat_dateOnlyStillParses() {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2025-02-01,gpt-4o,1000,500,200,300,2000,$0.10,$0.10
        """
        let row = try! XCTUnwrap(CursorUsageProcessing.parseCSV(csv).first)
        XCTAssertEqual(row.model, "gpt-4o")
        XCTAssertEqual(row.inputWithoutCache, 500)
        XCTAssertEqual(row.cacheWrite, 500)
        XCTAssertEqual(row.cacheRead, 200)
        XCTAssertEqual(row.outputTokens, 300)
        XCTAssertEqual(row.totalTokens, 2_000)
        // 日期：无时分秒 → UTC 当天 0 点。
        let expected = CursorUsageProcessing.bucketFloor(for: ISO8601DateFormatter().date(from: "2025-02-01T00:00:00Z")!)
        XCTAssertEqual(row.date.timeIntervalSince1970, expected.timeIntervalSince1970)
    }

    func test_parseCSV_headerOnlyOrEmptyReturnsNoRows() {
        XCTAssertTrue(CursorUsageProcessing.parseCSV("").isEmpty)
        XCTAssertTrue(CursorUsageProcessing.parseCSV("Date,Kind,Model\n").isEmpty)
    }

    func test_parseCSV_requiredColumnsMissingReturnsNoRows() {
        // 老格式缺 Cache Read 等必要列 → 一律不产出（防御式：宁可无数据不崩）。
        XCTAssertTrue(CursorUsageProcessing.parseCSV("Date,Model,Cost\n2026-02-01,auto,0.5").isEmpty)
    }

    func test_parseCSV_allZeroRowSkipped() {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-03-20T06:56:12.521Z","auto","0","0","0","0","0","0"
        """
        XCTAssertTrue(CursorUsageProcessing.parseCSV(csv).isEmpty, "全零行不产生计数")
    }

    func test_parseCSV_quotedFieldsAndQuotedTrimming() {
        let csv = """
        Date,Kind,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-03-20T06:56:12.521Z","Included in Pro","my-model-with-commas","50","40","10","5","55","0.00"
        """
        let row = try! XCTUnwrap(CursorUsageProcessing.parseCSV(csv).first)
        XCTAssertEqual(row.kind, "Included in Pro")
        XCTAssertEqual(row.cacheWrite, 10)
    }

    func test_parseCSV_unparseableDatesDropped() {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "not-a-date","auto","100","50","10","5","65","0"
        """
        XCTAssertTrue(CursorUsageProcessing.parseCSV(csv).isEmpty, "日期不可解析的行丢弃（对外不产生桶）")
    }

    // MARK: - 六列归一化 + 半小时桶

    func test_tokenUsage_mapsSixColumnsAndRecomputesTotal() throws {
        let row = try! XCTUnwrap(CursorUsageProcessing.parseCSV(
            "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost\n"
            + "\"2026-03-20T06:56:12.521Z\",auto,\"160000\",\"159990\",\"578207\",\"2055\",\"740252\",\"0.49\""
        ).first)
        let usage = try XCTUnwrap(CursorUsageProcessing.tokenUsage(from: row))
        XCTAssertEqual(usage.inputTokens, 159_990)
        XCTAssertEqual(usage.cachedInputTokens, 578_207)
        XCTAssertEqual(usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 2_055)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
        XCTAssertEqual(usage.totalTokens, 159_990 + 2_055, "total = input + output（缓存两列不计入总量）")
    }

    func test_bucketStates_groupsSameHalfHourAndSums() throws {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-03-20T06:12:12.521Z","auto","100","90","10","5","105","0.1"
        "2026-03-20T06:29:59.999Z","auto","50","40","20","5","65","0.1"
        "2026-03-20T07:00:00.000Z","auto","10","5","5","2","12","0.1"
        """
        let rows = CursorUsageProcessing.parseCSV(csv)
        let states = CursorUsageProcessing.bucketStates(rows: rows, provider: .cursor)
        XCTAssertEqual(states.count, 2, "06 半小时同模型合并；07 独立桶")
        // 06 桶：input 130 + output 10 = 140（缓存两列不计入总量）。
        let firstBucket = try XCTUnwrap(states.first { $0.key.model == "auto" && $0.usage.totalTokens == 140 })
        XCTAssertEqual(firstBucket.usage.inputTokens, 130, "90 + 40")
        XCTAssertEqual(firstBucket.usage.cachedInputTokens, 30, "10 + 20")
        XCTAssertEqual(firstBucket.usage.cacheCreationInputTokens, 20, "10 + 10")
        XCTAssertEqual(firstBucket.usage.outputTokens, 10, "5 + 5")
        XCTAssertEqual(firstBucket.conversationCount, 2)
        XCTAssertEqual(firstBucket.key.provider, .cursor, "provider 固定 cursor")
        let secondBucket = try XCTUnwrap(states.first { $0.usage.totalTokens == 5 + 2 })
        XCTAssertEqual(secondBucket.conversationCount, 1)
    }

    func test_bucketStates_emptyRowsNoBuckets() {
        XCTAssertTrue(CursorUsageProcessing.bucketStates(rows: [], provider: .cursor).isEmpty)
    }

    // MARK: - 模型名

    func test_normalizeModel_trimsAndDefaultsToUnknown() {
        XCTAssertEqual(CursorUsageProcessing.normalizeModel(" auto "), "auto")
        XCTAssertEqual(CursorUsageProcessing.normalizeModel(""), "unknown")
        XCTAssertEqual(CursorUsageProcessing.normalizeModel(nil), "unknown")
    }
}
