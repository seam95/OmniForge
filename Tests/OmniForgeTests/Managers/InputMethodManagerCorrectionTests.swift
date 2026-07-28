import XCTest
@testable import OmniForge

final class InputMethodManagerCorrectionTests: XCTestCase {
    func test_whenLockedAndMismatch_correctsBackAfterDelay() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )

        let scheduler = ImmediateScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "a")
    }

    func test_whenUnlocked_noCorrection() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )

        let scheduler = ImmediateScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        manager.correctIfNeeded(isLocked: false, lockedID: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "b")
    }
}
