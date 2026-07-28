import XCTest
@testable import OmniForge

final class FakeTISClientTests: XCTestCase {
    func test_selectChangesCurrentID() {
        let fake = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )

        XCTAssertEqual(fake.currentInputSourceID(), "a")
        XCTAssertTrue(fake.selectInputSource(id: "b"))
        XCTAssertEqual(fake.currentInputSourceID(), "b")
    }
}
