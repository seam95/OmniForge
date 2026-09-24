import XCTest
@testable import OmniForge

/// IPC 线上格式契约：载荷经 DistributedNotificationCenter 的 `object` 传递（非 `userInfo`），
/// 因为沙盒化的 FinderSync 扩展发送带 `userInfo` 的分布式通知会被系统拦截丢弃。
final class RightClickIPCMessageTests: XCTestCase {
    func test_decodesPayloadCarriedByNotificationObject() throws {
        // 与 FinderSyncIPC.postAction 产出的 JSON 形状一致
        let json = """
        {"actionType":"copyPath","parameter":"shellEscaped","targetURLs":["file:///tmp/a.txt"]}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.actionType, "copyPath")
        XCTAssertEqual(message.parameter, "shellEscaped")
        XCTAssertEqual(message.targetURLs, ["file:///tmp/a.txt"])
    }

    func test_decodesPayloadWithoutParameter() throws {
        let json = """
        {"actionType":"toggleHiddenFiles","targetURLs":[]}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.actionType, "toggleHiddenFiles")
        XCTAssertNil(message.parameter)
        XCTAssertTrue(message.targetURLs.isEmpty)
    }

    func test_decodesMultipleTargetURLs() throws {
        let json = """
        {"actionType":"moveTo","parameter":"/Users/seam/Desktop","targetURLs":["file:///tmp/a.txt","file:///tmp/b.txt"]}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.actionType, "moveTo")
        XCTAssertEqual(message.parameter, "/Users/seam/Desktop")
        XCTAssertEqual(message.targetURLs.count, 2)
    }

    func test_targetURLsResolveToFileURLs() throws {
        let json = """
        {"actionType":"newFile","parameter":"txt","targetURLs":["file:///tmp/of%20probe/"]}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))
        let urls = message.targetURLs.compactMap { URL(string: $0) }

        XCTAssertEqual(urls.count, 1)
        // 与 RightClickService.handleNotification 的还原路径一致
        XCTAssertEqual(urls.first?.path, "/tmp/of probe")
    }
}
