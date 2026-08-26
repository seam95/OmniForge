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
}
