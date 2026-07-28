import OmniForge
@testable import OmniForge
import XCTest

final class AXSnapAncestorTests: XCTestCase {
    /// AXUIElement 在测试中无法构造有意义的实例,改用 String 作为元素 token。
    /// smallestSnapAncestor 不关心元素类型,只通过注入的 reader 读属性。

    func test_达标元素直接返回() {
        // 链: leaf(frame 50x40,达标)
        let chain: [String: StubNode] = [
            "leaf": StubNode(frame: CGRect(x: 0, y: 0, width: 50, height: 40), role: "AXButton", parent: nil)
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "leaf",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertEqual(result?.rect.width, 50)
        XCTAssertEqual(result?.rect.height, 40)
        XCTAssertEqual(result?.isWindowFallback, false)
    }

    func test_叶子过小向上回溯到达标祖先() {
        // 链: small(10x8) → big(200x100)
        let chain: [String: StubNode] = [
            "small": StubNode(frame: CGRect(x: 0, y: 0, width: 10, height: 8), role: "AXButton", parent: "big"),
            "big": StubNode(frame: CGRect(x: 0, y: 0, width: 200, height: 100), role: "AXGroup", parent: nil)
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "small",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertEqual(result?.rect.width, 200)
        XCTAssertEqual(result?.isWindowFallback, false)
    }

    func test_全链不达标回退到窗口根() {
        // 链: tiny(5x5) → win(300x200, role=AXWindow) → nil
        let chain: [String: StubNode] = [
            "tiny": StubNode(frame: CGRect(x: 0, y: 0, width: 5, height: 5), role: "AXImage", parent: "win"),
            "win": StubNode(frame: CGRect(x: 0, y: 0, width: 300, height: 200), role: "AXWindow", parent: nil)
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "tiny",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertEqual(result?.rect.width, 300)
        XCTAssertEqual(result?.isWindowFallback, true)
    }

    func test_窗口根也不达标返回nil() {
        // 链: tiny(5x5) → win(8x8, role=AXWindow) → nil
        let chain: [String: StubNode] = [
            "tiny": StubNode(frame: CGRect(x: 0, y: 0, width: 5, height: 5), role: "AXImage", parent: "win"),
            "win": StubNode(frame: CGRect(x: 0, y: 0, width: 8, height: 8), role: "AXWindow", parent: nil)
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "tiny",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertNil(result)
    }

    func test_无窗口根的全链不达标返回nil() {
        // 链: tiny(5x5) → big(8x8, 非窗口) → nil
        let chain: [String: StubNode] = [
            "tiny": StubNode(frame: CGRect(x: 0, y: 0, width: 5, height: 5), role: "AXImage", parent: "big"),
            "big": StubNode(frame: CGRect(x: 0, y: 0, width: 8, height: 8), role: "AXGroup", parent: nil)
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "tiny",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertNil(result)
    }

    func test_深度上限防止循环() {
        // 构造一个循环链 a → b → a,确保不无限递归
        let chain: [String: StubNode] = [
            "a": StubNode(frame: nil, role: "AXGroup", parent: "b"),
            "b": StubNode(frame: nil, role: "AXGroup", parent: "a")
        ]
        let result = AXSnapAncestor.smallestSnapAncestor(
            of: "a",
            minSize: 20,
            frameReader: { chain[$0]?.frame },
            roleReader: { chain[$0]?.role },
            parentReader: { chain[$0]?.parent }
        )
        XCTAssertNil(result)  // 无 frame,无窗口根 → nil
    }

    private struct StubNode {
        let frame: CGRect?
        let role: String?
        let parent: String?
    }
}
