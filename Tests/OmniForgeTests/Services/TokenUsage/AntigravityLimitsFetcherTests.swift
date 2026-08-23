import XCTest
@testable import OmniForge

/// Antigravity 限额取数器：命令行匹配、quota summary bucketId 映射、
/// GetUserStatus 模型族分组、日期解析、lsof 端口解析与取数编排降级。
final class AntigravityLimitsFetcherTests: XCTestCase {
    // MARK: - 进程命令行匹配

    func test_processMatches_agyExecutableBasename() {
        XCTAssertTrue(AntigravityProcessProbe.matches("/usr/local/bin/agy --csrf_token abc"))
        XCTAssertTrue(AntigravityProcessProbe.matches("agy"))
        XCTAssertFalse(AntigravityProcessProbe.matches("vim /tmp/agy"), "参数中的 agy 不误判")
        XCTAssertFalse(AntigravityProcessProbe.matches("/bin/echo agy"))
    }

    func test_processMatches_languageServerRequiresAntigravityMarker() {
        XCTAssertTrue(AntigravityProcessProbe.matches(
            "/Applications/Antigravity.app/Contents/exa/codeium/language_server_macos --app_data_dir /Users/x/.antigravity --csrf_token tok-1 --extension_server_port 54321"
        ))
        XCTAssertTrue(AntigravityProcessProbe.matches(
            "language_server --override_ide_name antigravity"
        ))
        XCTAssertTrue(AntigravityProcessProbe.matches(
            "/opt/windsurf/language_server --app_data_dir /Users/x/.codeium\\antigravity\\x"
        ))
        XCTAssertFalse(AntigravityProcessProbe.matches(
            "/opt/windsurf/language_server --app_data_dir /Users/x/.codeium"
        ), "language_server 无 antigravity 标记 → 不匹配（Windsurf 兄弟产品）")
        XCTAssertFalse(AntigravityProcessProbe.matches("/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    func test_firstMatch_extractsPIDCSRFAndExtensionPort() {
        let output = """
          100 /sbin/launchd
          234 /Applications/Antigravity.app/Contents/exa/codeium/language_server_macos --csrf_token sec-9 --extension_server_port 54321
          999 agy
        """
        let match = AntigravityProcessProbe.firstMatch(in: output)
        XCTAssertEqual(match?.pid, 234)
        XCTAssertEqual(match?.csrfToken, "sec-9")
        XCTAssertEqual(match?.extensionPort, 54321)
    }

    func test_extractFlag_supportsEqualsAndSpaceForms() {
        XCTAssertEqual(AntigravityProcessProbe.extractFlag("cmd --csrf_token=tok1", "--csrf_token"), "tok1")
        XCTAssertEqual(AntigravityProcessProbe.extractFlag("cmd --csrf_token tok2", "--csrf_token"), "tok2")
        XCTAssertNil(AntigravityProcessProbe.extractFlag("cmd", "--csrf_token"))
    }

    // MARK: - quota summary 解码（bucketId 四窗）

    private func summaryBody(_ buckets: [[String: Any]]) -> [String: Any] {
        ["response": ["groups": [["buckets": buckets]]]]
    }

    private func bucket(_ id: String, remaining: Double, reset: Any? = 1_800_000_000) -> [String: Any] {
        var b: [String: Any] = ["bucketId": id, "remainingFraction": remaining]
        if let reset { b["resetTime"] = reset }
        return b
    }

    func test_quotaSummary_mapsKnownBucketIdsToLabeledWindows() throws {
        let labeled = try XCTUnwrap(AntigravityUsageDecoder.decodeQuotaSummary(summaryBody([
            bucket("3p-weekly", remaining: 0.7),
            bucket("3p-5h", remaining: 0.4),
            bucket("gemini-weekly", remaining: 0.9),
            bucket("gemini-5h", remaining: 0.2),
            bucket("unknown-bucket", remaining: 0.5),
        ])))
        XCTAssertEqual(labeled.map(\.label), ["Cl 7d", "Cl 5h", "Gm 7d", "Gm 5h"])
        XCTAssertEqual(labeled.map { $0.window.usedPercent }, [30, 60, 10, 80], "used = 100 − remaining×100")
        XCTAssertEqual(labeled.first?.window.resetAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func test_quotaSummary_noKnownBucketsReturnsNil() {
        XCTAssertNil(AntigravityUsageDecoder.decodeQuotaSummary(summaryBody([
            bucket("renamed-weekly", remaining: 0.5),
        ])), "上游改名 → nil 触发降级，不渲染空卡")
        XCTAssertNil(AntigravityUsageDecoder.decodeQuotaSummary(["response": ["groups": []]]))
        XCTAssertNil(AntigravityUsageDecoder.decodeQuotaSummary(["code": "error"]))
    }

    // MARK: - userStatus 模型族分组

    private func modelConfig(label: String, model: String, remaining: Double?) -> [String: Any] {
        var quota: [String: Any] = [:]
        if let remaining { quota["remainingFraction"] = remaining }
        return [
            "label": label,
            "modelOrAlias": ["model": model],
            "quotaInfo": quota,
        ]
    }

    func test_userStatus_groupsByFamilyAndPicksMinAndMax() throws {
        let body: [String: Any] = [
            "userStatus": [
                "email": "dev@example.com",
                "cascadeModelConfigData": [
                    "clientModelConfigs": [
                        modelConfig(label: "Claude Sonnet", model: "claude-sonnet", remaining: 0.6),
                        modelConfig(label: "Claude Opus", model: "claude-opus", remaining: 0.2),
                        modelConfig(label: "Gemini 3 Pro", model: "gemini-3-pro", remaining: 0.8),
                        modelConfig(label: "Gemini Flash", model: "gemini-flash", remaining: 0.3),
                        modelConfig(label: "Tab Autocomplete", model: "tab-model", remaining: 0.01),
                    ],
                ],
            ],
        ]
        let result = try XCTUnwrap(AntigravityUsageDecoder.decodeModelConfigBody(body))
        XCTAssertEqual(result.email, "dev@example.com")
        XCTAssertEqual(result.windows.map(\.label), ["Cl 7d", "Cl 5h", "Gm 7d", "Gm 5h"])
        XCTAssertEqual(result.windows[0].window.usedPercent, 80, "claude 族最低剩余(0.2) → 已用 80 → Cl 7d")
        XCTAssertEqual(result.windows[1].window.usedPercent, 40, "claude 族最高剩余(0.6) → 已用 40 → Cl 5h")
        XCTAssertEqual(result.windows[2].window.usedPercent, 70, "gemini 族最低剩余(0.3) → 已用 70 → Gm 7d")
        XCTAssertEqual(result.windows[3].window.usedPercent, 20, "gemini 族最高剩余(0.8) → 已用 20 → Gm 5h")
    }

    func test_userStatus_filtersNonChatModelsOnlyWhenChatExists() throws {
        let allNonChat: [String: Any] = [
            "userStatus": [
                "cascadeModelConfigData": [
                    "clientModelConfigs": [modelConfig(label: "Tab Lite", model: "tab_lite", remaining: 0.1)],
                ],
            ],
        ]
        let result = try XCTUnwrap(AntigravityUsageDecoder.decodeModelConfigBody(allNonChat))
        XCTAssertEqual(result.windows.count, 1, "全是非聊天模型 → 回退全集单窗兜底")
        XCTAssertEqual(result.windows.first?.label, "Cl 7d")
    }

    func test_userStatus_planLabelNormalization() {
        func status(_ plan: [String: Any]) -> [String: Any] {
            ["planStatus": ["planInfo": plan]]
        }
        XCTAssertEqual(
            AntigravityUsageDecoder.planLabel(from: status(["planDisplayName": "Antigravity Pro"])),
            "Pro", "剥前导品牌词"
        )
        XCTAssertEqual(
            AntigravityUsageDecoder.planLabel(from: status(["planDisplayName": "Team"])),
            "Team"
        )
        XCTAssertNil(AntigravityUsageDecoder.planLabel(from: status(["planDisplayName": "free"])))
        XCTAssertNil(AntigravityUsageDecoder.planLabel(from: status([:])))
        XCTAssertNil(AntigravityUsageDecoder.planLabel(from: nil))
    }

    func test_modelConfigBody_fallbackToConfigsReadsTopLevelArray() throws {
        let body: [String: Any] = [
            "clientModelConfigs": [modelConfig(label: "Claude", model: "claude-x", remaining: 0.25)],
        ]
        XCTAssertNil(AntigravityUsageDecoder.decodeModelConfigBody(body), "默认路径读不到顶层配置")
        let result = try XCTUnwrap(AntigravityUsageDecoder.decodeModelConfigBody(body, fallbackToConfigs: true))
        XCTAssertEqual(result.windows.first?.window.usedPercent, 75)
    }

    // MARK: - 日期解析

    func test_parseDate_numericSecondsAndISOStrings() {
        XCTAssertEqual(AntigravityUsageDecoder.parseDate(1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000), "数字按 unix 秒")
        XCTAssertEqual(AntigravityUsageDecoder.parseDate("1800000000"), Date(timeIntervalSince1970: 1_800_000_000), "数字串按 unix 秒")
        XCTAssertEqual(
            AntigravityUsageDecoder.parseDate("2027-01-15T08:00:00.000Z"),
            ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")
        )
        XCTAssertNil(AntigravityUsageDecoder.parseDate(nil))
        XCTAssertNil(AntigravityUsageDecoder.parseDate(0))
        XCTAssertNil(AntigravityUsageDecoder.parseDate("garbage"))
    }

    func test_codeIsOk_variants() {
        XCTAssertTrue(AntigravityUsageDecoder.antigravityCodeIsOk(nil))
        XCTAssertTrue(AntigravityUsageDecoder.antigravityCodeIsOk(0))
        XCTAssertTrue(AntigravityUsageDecoder.antigravityCodeIsOk("ok"))
        XCTAssertTrue(AntigravityUsageDecoder.antigravityCodeIsOk("success"))
        XCTAssertFalse(AntigravityUsageDecoder.antigravityCodeIsOk(1))
        XCTAssertFalse(AntigravityUsageDecoder.antigravityCodeIsOk("permission_denied"))
    }

    // MARK: - lsof 端口解析

    func test_listeningPorts_deduplicatedSorted() {
        let output = """
        COMMAND   PID USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
        agy     50001 seam  12u  IPv4  0xabcd      0t0  TCP *:8080 (LISTEN)
        agy     50001 seam  13u  IPv6  0xabce      0t0  TCP *:8080 (LISTEN)
        agy     50001 seam  14u  IPv4  0xabcf      0t0  TCP *:9443 (LISTEN)
        """
        XCTAssertEqual(AntigravityLimitsFetcher.parseListeningPorts(output), [8080, 9443])
        XCTAssertEqual(AntigravityLimitsFetcher.parseListeningPorts(""), [])
    }

    // MARK: - 取数编排

    /// 可编排的 shell 替身。
    private final class FakeShellRunner: @unchecked Sendable {
        struct Call {
            var launchPath: String
            var arguments: [String]
        }
        private let lock = NSLock()
        private var callsStorage: [Call] = []
        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return callsStorage }
        var psOutput: String = ""
        var lsofOutput: String = ""

        func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
            lock.lock()
            callsStorage.append(Call(launchPath: launchPath, arguments: arguments))
            lock.unlock()
            if launchPath.hasSuffix("ps") { return psOutput }
            if launchPath.hasSuffix("lsof") { return lsofOutput }
            return ""
        }
    }

    private final class FakeLocalClient: AntigravityLocalJSONPosting {
        var responses: [(pathSuffix: String, result: Result<[String: Any], Error>)] = []
        private(set) var probes: [(scheme: String, port: Int)] = []

        func postJSON(scheme: String, port: Int, path: String, body: [String: Any], csrfToken: String?) async throws -> [String: Any] {
            for entry in responses where path.hasSuffix(entry.pathSuffix) {
                return try entry.result.get()
            }
            throw LimitError.network("no stub for \(path)")
        }

        func probePort(scheme: String, port: Int, csrfToken: String?) async -> Bool {
            probes.append((scheme, port))
            return true
        }
    }

    private func makeFetcher(
        shell: FakeShellRunner,
        client: FakeLocalClient,
        hasInstall: Bool = false
    ) -> AntigravityLimitsFetcher {
        AntigravityLimitsFetcher(
            processRunner: { path, args, timeout in try await shell.run(path, args, timeout: timeout) },
            client: client,
            homeDirectory: { "/Users/tester" },
            installEvidence: { _ in hasInstall }
        )
    }

    private let languageServerLine =
        "  234 /Applications/Antigravity.app/Contents/exa/codeium/language_server_macos --csrf_token tok --extension_server_port 54321"

    func test_fetchLimits_noProcessNoInstallEvidence_returnsNotConfigured() async {
        let shell = FakeShellRunner()
        shell.psOutput = "  100 /sbin/launchd\n"
        let fetcher = makeFetcher(shell: shell, client: FakeLocalClient())
        do {
            let result = try await fetcher.fetchLimits(force: false)
            XCTAssertNil(result, "无进程且 ~/.gemini 无 antigravity 目录 → 未配置")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_noProcessWithInstallEvidence_reportsErrorState() async {
        let shell = FakeShellRunner()
        shell.psOutput = "  100 /sbin/launchd\n"
        let fetcher = makeFetcher(shell: shell, client: FakeLocalClient(), hasInstall: true)
        do {
            let result = try await fetcher.fetchLimits(force: false)
            XCTAssertEqual(result?.issue?.isNetworkLike ?? false, true, "有安装证据但进程不在 → 错误态（last-good 已先行兜底）")
            XCTAssertEqual(result?.configured, true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_quotaSummaryPrimaryPath() async throws {
        let shell = FakeShellRunner()
        shell.psOutput = languageServerLine
        shell.lsofOutput = "agy 50001 seam 12u IPv4 0x0 0t0 TCP *:9443 (LISTEN)"
        let client = FakeLocalClient()
        client.responses = [
            ("RetrieveUserQuotaSummary", .success(summaryBody([
                bucket("3p-weekly", remaining: 0.7),
                bucket("3p-5h", remaining: 0.4),
                bucket("gemini-weekly", remaining: 0.9),
            ]))),
        ]
        let limits = try await makeFetcher(shell: shell, client: client).fetchLimits(force: false)

        XCTAssertEqual(limits?.provider, .antigravity)
        XCTAssertNil(limits?.issue)
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 60, "Cl 5h → session 槽")
        XCTAssertEqual(limits?.windows[.weekly]?.usedPercent, 30, "Cl 7d → weekly 槽")
        XCTAssertEqual(limits?.labeledWindows?.map(\.label), ["Gm 7d"], "Gm 双窗保持带标签")
        XCTAssertTrue(client.probes.contains(where: { $0.scheme == "https" && $0.port == 9443 }))
    }

    func test_fetchLimits_fallsBackToUserStatusWhenSummaryUnavailable() async throws {
        let shell = FakeShellRunner()
        shell.psOutput = languageServerLine
        shell.lsofOutput = "agy 50001 seam 12u IPv4 0x0 0t0 TCP *:9443 (LISTEN)"
        let client = FakeLocalClient()
        client.responses = [
            ("RetrieveUserQuotaSummary", .failure(LimitError.network("HTTP 404"))),
            ("GetUserStatus", .success([
                "userStatus": [
                    "email": "dev@example.com",
                    "planStatus": ["planInfo": ["planDisplayName": "Antigravity Pro"]],
                    "cascadeModelConfigData": [
                        "clientModelConfigs": [
                            modelConfig(label: "Claude Sonnet", model: "claude-sonnet", remaining: 0.6),
                            modelConfig(label: "Claude Opus", model: "claude-opus", remaining: 0.2),
                        ],
                    ],
                ],
            ])),
        ]
        let limits = try await makeFetcher(shell: shell, client: client).fetchLimits(force: false)

        XCTAssertEqual(limits?.windows[.weekly]?.usedPercent, 80, "降级 GetUserStatus：族最低剩余(0.2) → Cl 7d/weekly")
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 40, "族最高剩余(0.6) → Cl 5h/session")
        XCTAssertEqual(limits?.planLabel, "Pro")
        XCTAssertEqual(limits?.subscriptionStatus, .active)
    }

    func test_fetchLimits_allSourcesFail_throwsDecoding() async {
        let shell = FakeShellRunner()
        shell.psOutput = languageServerLine
        shell.lsofOutput = "agy 50001 seam 12u IPv4 0x0 0t0 TCP *:9443 (LISTEN)"
        let client = FakeLocalClient()
        client.responses = [
            ("RetrieveUserQuotaSummary", .failure(LimitError.network("HTTP 404"))),
            ("GetUserStatus", .failure(LimitError.network("HTTP 500"))),
            ("GetCommandModelConfigs", .failure(LimitError.network("HTTP 500"))),
        ]
        do {
            _ = try await makeFetcher(shell: shell, client: client).fetchLimits(force: false)
            XCTFail("expected decoding error")
        } catch let error as LimitError {
            guard case .decoding = error else {
                XCTFail("expected decoding, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_noListeningPorts_reportsErrorState() async {
        let shell = FakeShellRunner()
        shell.psOutput = languageServerLine
        shell.lsofOutput = ""
        let fetcher = makeFetcher(shell: shell, client: FakeLocalClient())
        do {
            let result = try await fetcher.fetchLimits(force: false)
            XCTAssertEqual(result?.issue?.isNetworkLike ?? false, true, "进程在但无监听端口 → 错误态不崩")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private extension LimitError {
    var isNetworkLike: Bool {
        if case .network = self { return true }
        return false
    }
}
