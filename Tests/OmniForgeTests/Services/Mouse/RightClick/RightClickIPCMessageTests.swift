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

    // MARK: - IPC 共享令牌（防伪造分布式通知）

    /// 宿主要求载荷携带 App Group 共享令牌：带 token 的 JSON 必须能解码出原值。
    func test_decodesPayloadWithToken() throws {
        let json = """
        {"actionType":"copyTo","parameter":"/Users/seam/Desktop","targetURLs":["file:///tmp/a.txt"],"token":"11111111-2222-3333-4444-555555555555"}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.token, "11111111-2222-3333-4444-555555555555")
    }

    /// 向后兼容旧版扩展的一次发布窗口：不含 token 字段的 JSON 解码为 nil，而非解码失败。
    /// （宿主侧对 nil token 一律拒绝执行；此兼容只保证解码不崩。）
    func test_decodesPayloadWithoutToken_tokenIsNil() throws {
        let json = """
        {"actionType":"moveTo","parameter":"/Users/seam/Desktop","targetURLs":[]}
        """

        let message = try JSONDecoder().decode(RightClickIPCMessage.self, from: Data(json.utf8))

        XCTAssertNil(message.token)
    }

    /// 锁定扩展产出的载荷形状：编码后的 JSON 必须携带 token 字段上链。
    func test_encodesTokenIntoPayloadJSON() throws {
        let message = RightClickIPCMessage(
            actionType: "copyPath",
            parameter: "posix",
            targetURLs: ["file:///tmp/a.txt"],
            token: "11111111-2222-3333-4444-555555555555"
        )

        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["token"] as? String, "11111111-2222-3333-4444-555555555555")
    }
}
