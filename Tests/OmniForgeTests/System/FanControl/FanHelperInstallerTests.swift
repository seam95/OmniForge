import XCTest
import OmniForgeSMC
import ServiceManagement
@testable import OmniForge

final class FanHelperInstallerTests: XCTestCase {

    func test_plistName_matchesBundleConvention() {
        XCTAssertEqual(FanHelperInstaller.plistName, "app.omniforge.fan-helper.plist",
                       "plist 文件名必须与 build.sh 复制进 LaunchDaemons 的文件名一致")
    }

    func test_isVersionMatched() {
        XCTAssertTrue(FanHelperInstaller.isVersionMatched(kFanHelperVersion))
        XCTAssertFalse(FanHelperInstaller.isVersionMatched("0.9.0"),
                       "旧版本应提示重装")
        XCTAssertFalse(FanHelperInstaller.isVersionMatched(nil),
                       "连不上（版本未知）按不匹配处理")
    }

    // MARK: - register() 抛错后的处置判定

    /// 首次注册 macOS 同步抛 code=1 并弹通知等批准：requiresApproval 是正常中间态，
    /// 不得当终态失败展示（否则用户批准后 UI 卡死在"失败"直到重启 app）
    func test_outcome_firstRegistrationRejection_isAwaitingApproval() {
        let error = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        XCTAssertEqual(
            FanHelperInstaller.outcome(afterRegisterError: error, status: .requiresApproval),
            .awaitingApproval
        )
    }

    func test_outcome_errorButEnabled_isEnabled() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        XCTAssertEqual(
            FanHelperInstaller.outcome(afterRegisterError: error, status: .enabled),
            .enabled
        )
    }

    func test_outcome_notRegisteredAfterError_isFailedWithDiagnostic() {
        let error = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        guard case .failed(let message) =
            FanHelperInstaller.outcome(afterRegisterError: error, status: .notRegistered)
        else {
            return XCTFail("未登记状态的报错应为真失败")
        }
        XCTAssertTrue(message.contains("SMAppServiceErrorDomain 1"),
                      "失败文案须携带 domain+code 供定位，实际：\(message)")
    }
}
