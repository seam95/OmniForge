import XCTest
@testable import OmniForge

final class DeviceSummaryProviderTests: XCTestCase {
    func test_usesFallbackHostNameWhenNil() {
        let provider = DeviceSummaryProvider(
            hostNameProvider: { nil },
            osVersionProvider: { .init(majorVersion: 15, minorVersion: 7, patchVersion: 0) },
            bootDateProvider: { nil }
        )
        let summary = provider.makeSummary(fallbackHostName: "Mac")
        XCTAssertEqual(summary.hostName, "Mac")
        XCTAssertEqual(summary.osVersionText, "macOS 15.7.0")
        XCTAssertNil(summary.uptimeText)
    }

    func test_formatsUptime() {
        let boot = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 14 * 3600 + 2 * 60)
        XCTAssertEqual(DeviceSummaryProvider.formatUptime(from: boot, now: now), "14:02")
    }

    func test_subtitlePartsIndependent() {
        let provider = DeviceSummaryProvider(
            hostNameProvider: { "Studio" },
            osVersionProvider: { .init(majorVersion: 15, minorVersion: 7, patchVersion: 1) },
            bootDateProvider: { Date(timeIntervalSince1970: 0) }
        )
        let summary = provider.makeSummary(now: Date(timeIntervalSince1970: 60), fallbackHostName: "Mac")
        XCTAssertEqual(summary.hostName, "Studio")
        XCTAssertEqual(summary.osVersionText, "macOS 15.7.1")
        XCTAssertEqual(summary.uptimeText, "0:01")
    }
}
