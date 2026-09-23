import XCTest
@testable import OmniForge

/// TOML 行级子集：解析/序列化原样保留、值读写、转义往返。
final class ProviderSwitchTOMLFileTests: XCTestCase {
    func test_parse_roundTripsUnchangedContent() throws {
        let text = """
        # OpenAI API key configuration
        model = "gpt-5"
        model_provider = "openai"
        model_reasoning_effort = "medium"   # 注释

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
        """
        let document = try XCTUnwrap(TOMLFile.parse(text))
        XCTAssertEqual(document.serialize(), text + "\n", "未知内容与注释必须原样保留")
    }

    func test_parse_readsTopLevelAndTableValues() throws {
        let document = try XCTUnwrap(TOMLFile.parse("""
        model = "gpt-5"
        model_provider = "glm"

        [model_providers.glm]
        name = "GLM"
        base_url = 'https://open.bigmodel.cn/api/paas/v4'
        wire_api = "chat"
        """))
        XCTAssertEqual(document.stringValue(key: "model", table: nil), "gpt-5")
        XCTAssertEqual(document.stringValue(key: "model_provider", table: nil), "glm")
        XCTAssertEqual(document.stringValue(key: "name", table: ["model_providers", "glm"]), "GLM")
        XCTAssertEqual(
            document.stringValue(key: "base_url", table: ["model_providers", "glm"]),
            "https://open.bigmodel.cn/api/paas/v4",
            "字面量字符串（单引号）"
        )
        XCTAssertEqual(document.stringValue(key: "wire_api", table: ["model_providers", "glm"]), "chat")
        XCTAssertNil(document.stringValue(key: "missing", table: nil))
        XCTAssertNil(document.stringValue(key: "name", table: nil), "表内键不属于顶层")
    }

    func test_parse_boolAndBareValues() throws {
        let document = try XCTUnwrap(TOMLFile.parse("""
        enabled = true
        count = 42
        ratio = 1.5
        """))
        XCTAssertEqual(document.stringValue(key: "enabled", table: nil), "true")
        XCTAssertEqual(document.stringValue(key: "count", table: nil), "42")
        XCTAssertEqual(document.stringValue(key: "ratio", table: nil), "1.5")
    }

    func test_parse_unterminatedStringIsCorrupted() {
        XCTAssertNil(TOMLFile.parse("model = \"unterminated"))
        XCTAssertNil(TOMLFile.parse("not a toml line"))
        XCTAssertNil(TOMLFile.parse("model_provider = 'unterminated"))
    }

    func test_parse_emptyAndCommentOnly() {
        XCTAssertNotNil(TOMLFile.parse(""))
        XCTAssertNotNil(TOMLFile.parse("# 只有注释\n\n"))
        XCTAssertNil(TOMLFile.parse("   = x"), "缺键")
    }

    func test_setValue_updatesExistingKeepingComment() throws {
        var document = try XCTUnwrap(TOMLFile.parse("model = \"gpt-5\" # 主模型\nmodel_provider = \"openai\"\n"))
        document.setValue("glm-4-7", key: "model", table: nil)
        let text = document.serialize()
        XCTAssertEqual(text, "model = \"glm-4-7\" # 主模型\nmodel_provider = \"openai\"\n")
    }

    func test_setValue_appendsTopLevelBeforeFirstTable() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model = "gpt-5"

        [model_providers.openai]
        name = "OpenAI"
        """))
        document.setValue("glm", key: "model_provider", table: nil)
        XCTAssertEqual(document.serialize(), """
        model = "gpt-5"
        model_provider = "glm"

        [model_providers.openai]
        name = "OpenAI"
        """ + "\n")
    }

    func test_setValue_appendsToTableAfterExistingEntries() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        [model_providers.glm]
        name = "GLM"
        wire_api = "chat"
        """))
        document.setValue("sk-secret", key: "experimental_bearer_token", table: ["model_providers", "glm"])
        document.setValue("https://example.com", key: "base_url", table: ["model_providers", "glm"])
        XCTAssertEqual(document.serialize(), """
        [model_providers.glm]
        name = "GLM"
        wire_api = "chat"
        experimental_bearer_token = "sk-secret"
        base_url = "https://example.com"
        """ + "\n")
    }

    func test_ensureTable_addsMissingTableAtEnd() throws {
        var document = try XCTUnwrap(TOMLFile.parse("model_provider = \"glm\"\n"))
        document.ensureTable(path: ["model_providers", "glm"])
        document.setValue("GLM", key: "name", table: ["model_providers", "glm"])
        XCTAssertEqual(document.serialize(), """
        model_provider = "glm"

        [model_providers.glm]
        name = "GLM"
        """ + "\n")
    }

    func test_ensureTable_isIdempotent() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        [model_providers.glm]
        name = "GLM"
        """))
        document.ensureTable(path: ["model_providers", "glm"])
        document.setValue("GLM 2", key: "name", table: ["model_providers", "glm"])
        XCTAssertEqual(document.serialize(), """
        [model_providers.glm]
        name = "GLM 2"
        """ + "\n")
    }

    func test_remove_deletesLine() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model = "gpt-5" # keep
        model_provider = "glm" # gone
        """))
        document.remove(key: "model_provider", table: nil)
        XCTAssertEqual(document.serialize(), "model = \"gpt-5\" # keep\n")
    }

    func test_removeTable_deletesHeaderAndBody() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model_provider = "glm"
        model = "glm-4-7"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://example.com"
        experimental_bearer_token = "sk-x"

        [model_providers.kimi]
        name = "Kimi"
        """))
        document.removeTable(path: ["model_providers", "glm"])
        XCTAssertEqual(document.serialize(), """
        model_provider = "glm"
        model = "glm-4-7"

        [model_providers.kimi]
        name = "Kimi"
        """ + "\n")
    }

    func test_escapeAndUnescape_roundTrip() {
        let tricky = "sk-abc\"\\\n\t中-文#值"
        let escaped = TOMLFile.escape(tricky)
        // unescape 语义与 stringValue 一致：入参为剥去外层引号的内容。
        XCTAssertEqual(TOMLFile.unescape(String(escaped.dropFirst().dropLast())), tricky)
    }

    func test_escape_handlesControlCharacters() {
        XCTAssertEqual(TOMLFile.escape("a\u{01}b"), "\"a\\u0001b\"")
    }

    func test_parse_equalsInsideQuotedValue() throws {
        let document = try XCTUnwrap(TOMLFile.parse("token = \"a=b=c\"\n"))
        XCTAssertEqual(document.stringValue(key: "token", table: nil), "a=b=c")
    }

    // MARK: - 行号一致性回归（R01：规范化前缀回查未改写原文导致行号越界）

    /// 断言所有条目行号有效且行内容与词法前缀匹配——每次结构修改后都应成立。
    private func assertEntriesValid(
        _ document: TOMLFile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for entry in document.entries {
            XCTAssertGreaterThanOrEqual(entry.lineIndex, 0, file: file, line: line)
            XCTAssertLessThan(
                entry.lineIndex,
                document.lines.count,
                "行号越界：\(entry.key) → \(entry.lineIndex)（共 \(document.lines.count) 行）",
                file: file, line: line
            )
            if entry.lineIndex < document.lines.count {
                XCTAssertTrue(
                    document.lines[entry.lineIndex].hasPrefix(entry.prefix),
                    "条目行不匹配：\(entry.key) prefix=\(entry.prefix.debugDescription) 实际行=\(document.lines[entry.lineIndex].debugDescription)",
                    file: file, line: line
                )
            }
        }
    }

    /// 回归：无空格原文 `model="old"` 上先插入新键再更新旧键，
    /// 旧行号按格式化前缀回查会匹配失败并把索引推到 lines.count 之外（越界崩溃）。
    func test_setValue_noSpaceOriginal_keepsIndexesValidAcrossEdits() throws {
        var document = try XCTUnwrap(TOMLFile.parse("model=\"old\"\n"))
        assertEntriesValid(document)

        // 与生产链一致：先插入 model_provider，再原地更新 model。
        document.setValue("glm", key: "model_provider", table: nil)
        assertEntriesValid(document)
        document.setValue("glm-4-7", key: "model", table: nil)
        assertEntriesValid(document)

        XCTAssertEqual(document.stringValue(key: "model", table: nil), "glm-4-7")
        XCTAssertEqual(document.stringValue(key: "model_provider", table: nil), "glm")
        let reparsed = try XCTUnwrap(TOMLFile.parse(document.serialize()))
        XCTAssertEqual(reparsed.stringValue(key: "model", table: nil), "glm-4-7")
        XCTAssertEqual(reparsed.stringValue(key: "model_provider", table: nil), "glm")
    }

    /// 回归：多空格 / Tab 缩进 / 行尾注释的原文，连续增删改后全部索引保持有效。
    func test_mixedSpacingOriginal_survivesConsecutiveEdits() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        \tmodel  =  "old"   # 主模型
        [model_providers.kimi]
        \tname = "Kimi"
        """))
        assertEntriesValid(document)

        document.setValue("k2", key: "model", table: nil)
        assertEntriesValid(document)
        document.setValue("glm", key: "model_provider", table: nil)
        assertEntriesValid(document)
        document.setValue("https://example.com", key: "base_url", table: ["model_providers", "kimi"])
        assertEntriesValid(document)
        document.remove(key: "name", table: ["model_providers", "kimi"])
        assertEntriesValid(document)
        document.setValue("Kimi 2", key: "name", table: ["model_providers", "kimi"])
        assertEntriesValid(document)
        document.removeTable(path: ["model_providers", "kimi"])
        assertEntriesValid(document)
        document.normalizeBlankLines()
        assertEntriesValid(document)

        // 序列化再解析语义一致。
        let reparsed = try XCTUnwrap(TOMLFile.parse(document.serialize()))
        XCTAssertEqual(reparsed.stringValue(key: "model", table: nil), "k2")
        XCTAssertEqual(reparsed.stringValue(key: "model_provider", table: nil), "glm")
        assertEntriesValid(reparsed)
    }

    /// 同名前缀键（model / model_provider）交错编辑不得串行。
    func test_samePrefixKeys_neverCrossMatch() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model = "a"
        model_provider = "b"
        """))
        document.setValue("c", key: "model", table: nil)
        document.setValue("d", key: "model_provider", table: nil)
        document.setValue("e", key: "model", table: nil)
        assertEntriesValid(document)
        XCTAssertEqual(document.stringValue(key: "model", table: nil), "e")
        XCTAssertEqual(document.stringValue(key: "model_provider", table: nil), "d")
    }

    /// 多表间连续插入/删除，索引在跨表位移后仍全部有效。
    func test_multipleTables_insertRemoveKeepsIndexesValid() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model = "old"

        [a]
        key1 = "1"

        [b]
        key2 = "2"

        [c]
        key3 = "3"
        """))
        document.setValue("4", key: "key4", table: ["b"])
        assertEntriesValid(document)
        document.setValue("new", key: "model", table: nil)
        assertEntriesValid(document)
        document.removeTable(path: ["a"])
        assertEntriesValid(document)
        document.setValue("5", key: "key5", table: ["c"])
        assertEntriesValid(document)
        document.remove(key: "key2", table: ["b"])
        assertEntriesValid(document)

        XCTAssertEqual(document.stringValue(key: "key5", table: ["c"]), "5")
        XCTAssertEqual(document.stringValue(key: "key4", table: ["b"]), "4")
    }

    func test_booleanValue_and_setBooleanValue() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        model = "gpt-5"

        [model_providers.custom]
        name = "custom"
        requires_openai_auth = false   # 旧值
        """))
        XCTAssertEqual(document.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]), false)

        // 原地更新为 true，保留行尾注释
        document.setBooleanValue(true, key: "requires_openai_auth", table: ["model_providers", "custom"])
        XCTAssertEqual(document.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]), true)
        XCTAssertTrue(document.serialize().contains("requires_openai_auth = true   # 旧值"))

        // 追加新布尔键
        document.setBooleanValue(false, key: "is_disabled", table: ["model_providers", "custom"])
        XCTAssertEqual(document.booleanValue(key: "is_disabled", table: ["model_providers", "custom"]), false)
        XCTAssertTrue(document.serialize().contains("is_disabled = false"))
    }

    // MARK: - 字符串数组

    func test_stringArrayValue_readsAndRoundTrips() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        models = ["glm-5.3", "glm-4.7-air"]
        model_provider = "glm"
        """))
        XCTAssertEqual(document.stringArrayValue(key: "models", table: nil), ["glm-5.3", "glm-4.7-air"])

        document.setValue(["gpt-5.6", "gpt-5.6-mini"], key: "models", table: nil)
        XCTAssertEqual(
            document.serialize(),
            """
            models = ["gpt-5.6", "gpt-5.6-mini"]
            model_provider = "glm"

            """
        )
        XCTAssertEqual(document.stringArrayValue(key: "models", table: nil), ["gpt-5.6", "gpt-5.6-mini"])
    }

    func test_stringArrayValue_emptyArray() throws {
        var document = try XCTUnwrap(TOMLFile.parse("models = [\"a\"]\n"))
        document.setValue([], key: "models", table: nil)
        XCTAssertEqual(document.stringArrayValue(key: "models", table: nil), [])
        XCTAssertTrue(document.serialize().contains("models = []"))
    }

    func test_stringArrayValue_updatesExistingKeepingComment() throws {
        var document = try XCTUnwrap(TOMLFile.parse("models = [\"a\"] # 模型\n"))
        document.setValue(["b", "c"], key: "models", table: nil)
        XCTAssertTrue(document.serialize().contains("models = [\"b\", \"c\"] # 模型"))
        XCTAssertEqual(document.stringArrayValue(key: "models", table: nil), ["b", "c"])
    }

    func test_stringArrayValue_escapesAndKeepsCommasInsideElements() throws {
        var document = TOMLFile()
        let tricky = "mo\"del, \\ #1"
        document.setValue([tricky, "plain"], key: "models", table: nil)
        let reparsed = try XCTUnwrap(TOMLFile.parse(document.serialize()))
        XCTAssertEqual(reparsed.stringArrayValue(key: "models", table: nil), [tricky, "plain"])
    }

    func test_stringArrayValue_appendsToTableAfterExistingEntries() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        [model_providers.glm]
        name = "GLM"
        """))
        document.setValue(["a", "b"], key: "models", table: ["model_providers", "glm"])
        XCTAssertEqual(document.stringArrayValue(key: "models", table: ["model_providers", "glm"]), ["a", "b"])
        XCTAssertTrue(document.serialize().hasSuffix("""
        [model_providers.glm]
        name = "GLM"
        models = ["a", "b"]

        """))
    }

    func test_stringArrayValue_rejectsNonArrayAndMissingKey() throws {
        let document = try XCTUnwrap(TOMLFile.parse("""
        model = "gpt-5"
        flag = true
        models = "glm-5.3"
        numbers = [1, 2]
        """))
        XCTAssertNil(document.stringArrayValue(key: "model", table: nil))
        XCTAssertNil(document.stringArrayValue(key: "flag", table: nil))
        XCTAssertNil(document.stringArrayValue(key: "models", table: nil), "字符串不是数组")
        XCTAssertNil(document.stringArrayValue(key: "numbers", table: nil), "非字符串元素不在支持范围")
        XCTAssertNil(document.stringArrayValue(key: "missing", table: nil))
    }

    func test_remove_deletesArrayLine() throws {
        var document = try XCTUnwrap(TOMLFile.parse("""
        models = ["a", "b"]
        model_provider = "glm"
        """))
        document.remove(key: "models", table: nil)
        XCTAssertNil(document.stringArrayValue(key: "models", table: nil))
        XCTAssertEqual(document.serialize(), """
        model_provider = "glm"

        """)
    }
}
