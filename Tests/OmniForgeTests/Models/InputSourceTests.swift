import XCTest
@testable import OmniForge

final class InputSourceTests: XCTestCase {
    func test_initStoresFields() {
        let source = InputSource(
            id: "com.test.abc",
            name: "ABC",
            isSelectable: true,
            isEnabled: true,
            icon: nil
        )

        XCTAssertEqual(source.id, "com.test.abc")
        XCTAssertEqual(source.name, "ABC")
        XCTAssertTrue(source.isSelectable)
        XCTAssertTrue(source.isEnabled)
    }
}
