import XCTest
@testable import OmniForge

final class InputMethodManagerTests: XCTestCase {
    func test_enumerateReturnsClientList() {
        let fake = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )

        let manager = InputMethodManager(tis: fake)
        XCTAssertEqual(manager.enumerateInputSources().map(\.id), ["a", "b"])
    }

    func test_getCurrentReturnsCurrentByID() {
        let fake = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )

        let manager = InputMethodManager(tis: fake)
        XCTAssertEqual(manager.getCurrentInputSource()?.id, "a")
    }
}
