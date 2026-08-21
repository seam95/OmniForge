import XCTest
@testable import OmniForge

final class DSHWebServiceDiscoveryTests: XCTestCase {
    func test_isDSHWebCommand_acceptsWebAlias() {
        let command = "node /Users/test/.nvm/lib/node_modules/@deepseek-ai/dsh/lib/bin.js web --port 8080"

        XCTAssertTrue(DSHWebServiceSupport.isDSHWebCommand(command))
    }

    /// npm 全局 bin 是符号链接时，ps 保留用户调用的 `.../bin/dsh` 路径。
    func test_isDSHWebCommand_acceptsGlobalDSHBinAlias() {
        let command = "node /Users/test/.nvm/versions/node/v22/bin/dsh web"

        XCTAssertTrue(DSHWebServiceSupport.isDSHWebCommand(command))
    }

    func test_isDSHWebCommand_acceptsExplicitWebProfile() {
        let command = "node /tmp/@deepseek-ai/dsh/lib/bin.js --profile web --port 8080"

        XCTAssertTrue(DSHWebServiceSupport.isDSHWebCommand(command))
    }

    func test_isDSHWebCommand_rejectsOrdinaryNodeServerAndOtherDSHProfile() {
        XCTAssertFalse(DSHWebServiceSupport.isDSHWebCommand("node /tmp/server.js --port 8080"))
        XCTAssertFalse(DSHWebServiceSupport.isDSHWebCommand(
            "node /tmp/@deepseek-ai/dsh/lib/bin.js --profile tui"
        ))
        XCTAssertFalse(DSHWebServiceSupport.isDSHWebCommand(
            "node /tmp/@deepseek-ai/dsh/lib/bin.js --profile tui web"
        ))
    }

    func test_isSameInstance_requiresPIDPortAndCommandAllMatch() {
        let service = DSHWebService(
            pid: 42,
            port: 8080,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8080"
        )
        let changedCommand = DSHWebService(
            pid: 42,
            port: 8080,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8081"
        )

        XCTAssertTrue(DSHWebServiceSupport.isSameInstance(service, service))
        XCTAssertFalse(DSHWebServiceSupport.isSameInstance(service, changedCommand))
    }
}
