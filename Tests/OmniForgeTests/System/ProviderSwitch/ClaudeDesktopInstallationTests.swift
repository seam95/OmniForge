import XCTest
@testable import OmniForge

/// Desktop 安装信息与生效诊断（SPEC 关键设计决策 8：不设版本门槛，只提示）：
/// 未安装 / 未应用 / 可能不支持（带版本号）/ 生效 四态。
final class ClaudeDesktopInstallationTests: XCTestCase {
    private func state(
        appliedId: String?,
        baseURL: String?
    ) -> ClaudeDesktopState {
        ClaudeDesktopState(
            deploymentMode: "3p",
            appliedId: appliedId,
            inferenceGatewayBaseUrl: baseURL,
            inferenceGatewayApiKey: "sk",
            isOurProfileApplied: appliedId == ClaudeDesktopSettingsStore.profileID
        )
    }

    private let installed = ClaudeDesktopInstallation(version: "3.6556.2", isInstalled: true)

    func test_diagnose_activeWhenAppliedAndBaseURLMatches() {
        let diagnosis = ClaudeDesktopSetupDiagnoser.diagnose(
            state: state(appliedId: ClaudeDesktopSettingsStore.profileID, baseURL: "https://x.example/anthropic"),
            expectedBaseURL: "https://x.example/anthropic",
            installation: installed
        )
        XCTAssertEqual(diagnosis, .active)
    }

    func test_diagnose_notInstalledTakesPriority() {
        let diagnosis = ClaudeDesktopSetupDiagnoser.diagnose(
            state: state(appliedId: ClaudeDesktopSettingsStore.profileID, baseURL: "https://x"),
            expectedBaseURL: "https://x",
            installation: ClaudeDesktopInstallation(version: nil, isInstalled: false)
        )
        XCTAssertEqual(diagnosis, .notInstalled)
    }

    func test_diagnose_notAppliedWhenOtherProfileIsApplied() {
        let diagnosis = ClaudeDesktopSetupDiagnoser.diagnose(
            state: state(appliedId: "someone-else", baseURL: "https://x"),
            expectedBaseURL: "https://x",
            installation: installed
        )
        XCTAssertEqual(diagnosis, .notApplied)
    }

    /// appliedId 是我们但网关地址被改过（外部修改）→ 同样按未生效处理。
    func test_diagnose_notAppliedWhenBaseURLDiffers() {
        let diagnosis = ClaudeDesktopSetupDiagnoser.diagnose(
            state: state(appliedId: ClaudeDesktopSettingsStore.profileID, baseURL: "https://changed"),
            expectedBaseURL: "https://expected",
            installation: installed
        )
        XCTAssertEqual(diagnosis, .notApplied)
    }

    func test_fallbackForUnappliedCarriesInstalledVersion() {
        XCTAssertEqual(
            ClaudeDesktopSetupDiagnoser.fallbackForUnapplied(installation: installed),
            .possiblyUnsupported(version: "3.6556.2")
        )
    }

    func test_installationReader_reportsMissingAppWithoutCrashing() {
        // 用不存在的 home 路径：不应崩、应返回未安装。
        let result = ClaudeDesktopInstallationReader.read(homePath: "/nonexistent-home-for-test")
        XCTAssertFalse(result.isInstalled)
        XCTAssertNil(result.version)
        XCTAssertNil(result.displayVersion)
    }

    func test_diagnosisSummariesAreNonEmpty() {
        for diagnosis in [
            ClaudeDesktopSetupDiagnosis.active,
            .notApplied,
            .possiblyUnsupported(version: "3.6556.2"),
            .possiblyUnsupported(version: nil),
            .notInstalled,
        ] {
            XCTAssertFalse(diagnosis.summary.isEmpty)
        }
    }
}
