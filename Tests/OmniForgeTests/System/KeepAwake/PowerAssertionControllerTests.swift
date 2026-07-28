import IOKit.pwr_mgt
import XCTest
@testable import OmniForge

final class PowerAssertionControllerTests: XCTestCase {
    func test_acquire_usesSystemAndDisplayAssertionTypesAndReasons() throws {
        var createCalls: [(type: String, name: String)] = []
        var nextID: IOPMAssertionID = 10
        let api = PowerAssertionAPI(
            createWithName: { type, level, name, idPtr in
                createCalls.append((
                    type: type as String,
                    name: name as String
                ))
                XCTAssertEqual(level, IOPMAssertionLevel(kIOPMAssertionLevelOn))
                idPtr.pointee = nextID
                nextID += 1
                return kIOReturnSuccess
            },
            release: { _ in kIOReturnSuccess }
        )
        let controller = PowerAssertionController(api: api)

        let system = try controller.acquireSystemAssertion(reason: "OmniForge KeepAwake System")
        let display = try controller.acquireDisplayAssertion(reason: "OmniForge KeepAwake Display")

        XCTAssertEqual(system.kind, .system)
        XCTAssertEqual(display.kind, .display)
        XCTAssertNotEqual(system.assertionID, display.assertionID)
        XCTAssertEqual(createCalls.count, 2)
        XCTAssertEqual(createCalls[0].type, kIOPMAssertionTypeNoIdleSleep as String)
        XCTAssertEqual(createCalls[0].name, "OmniForge KeepAwake System")
        XCTAssertEqual(createCalls[1].type, kIOPMAssertionTypeNoDisplaySleep as String)
        XCTAssertEqual(createCalls[1].name, "OmniForge KeepAwake Display")
    }

    func test_acquireFailure_preservesIOReturnCode() {
        let api = PowerAssertionAPI(
            createWithName: { _, _, _, _ in kIOReturnNotPrivileged },
            release: { _ in kIOReturnSuccess }
        )
        let controller = PowerAssertionController(api: api)
        XCTAssertThrowsError(try controller.acquireSystemAssertion(reason: "r")) { error in
            XCTAssertEqual(error as? KeepAwakeError, .systemAssertionFailed(code: kIOReturnNotPrivileged))
        }
        XCTAssertThrowsError(try controller.acquireDisplayAssertion(reason: "r")) { error in
            XCTAssertEqual(error as? KeepAwakeError, .displayAssertionFailed(code: kIOReturnNotPrivileged))
        }
    }

    func test_releaseFailure_isExplicitAndDoesNotPretendSuccess() throws {
        var released: [IOPMAssertionID] = []
        let api = PowerAssertionAPI(
            createWithName: { _, _, _, idPtr in
                idPtr.pointee = 42
                return kIOReturnSuccess
            },
            release: { id in
                released.append(id)
                return kIOReturnError
            }
        )
        let controller = PowerAssertionController(api: api)
        let token = try controller.acquireSystemAssertion(reason: "r")
        XCTAssertThrowsError(try controller.release(token)) { error in
            XCTAssertEqual(
                error as? KeepAwakeError,
                .assertionReleaseFailed(kind: "system", code: kIOReturnError)
            )
        }
        XCTAssertEqual(released, [42])
    }
}
