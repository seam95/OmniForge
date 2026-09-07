import XCTest
import OmniForgeSMC
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
}
