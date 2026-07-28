import Combine
import XCTest
@testable import OmniForge

@MainActor
final class PermissionsScreenRecordingTests: XCTestCase {
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
        Permissions.shared.resetForTesting()
    }

    override func tearDown() {
        cancellables = nil
        Permissions.shared.resetForTesting()
        super.tearDown()
    }

    func test_resetForTesting_clearsScreenRecording() {
        Permissions.shared.setScreenRecordingForTesting(true)
        XCTAssertTrue(Permissions.shared.screenRecording)
        Permissions.shared.resetForTesting()
        XCTAssertFalse(Permissions.shared.screenRecording)
    }

    func test_setScreenRecordingForTesting_publishesValue() {
        let expectation = expectation(description: "screenRecording published")
        Permissions.shared.$screenRecording
            .dropFirst()
            .sink { value in
                XCTAssertTrue(value)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        Permissions.shared.setScreenRecordingForTesting(true)
        wait(for: [expectation], timeout: 1)
    }

    func test_featuresRequiring_screenRecording_includesScreenshotWhenAvailable() {
        let features = AppFeature.featuresRequiring(
            .screenRecording,
            isAvailable: { $0 == .screenshot },
            isPermissionGranted: { _ in false }
        )
        XCTAssertEqual(features, [.screenshot])
    }

    func test_permissionsPortal_isPermissionGranted_mapsScreenRecording() {
        Permissions.shared.setScreenRecordingForTesting(false)
        XCTAssertFalse(
            PermissionsPortalState.isPermissionGranted(.screenRecording, permissions: .shared)
        )
        Permissions.shared.setScreenRecordingForTesting(true)
        XCTAssertTrue(
            PermissionsPortalState.isPermissionGranted(.screenRecording, permissions: .shared)
        )
    }
}
