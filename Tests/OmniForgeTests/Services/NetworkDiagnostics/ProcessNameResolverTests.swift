import XCTest
@testable import OmniForge

final class ProcessNameResolverTests: XCTestCase {

    func test_prefersRunningApplicationLocalizedName() {
        let resolver = ProcessNameResolver(
            runningAppName: { pid in
                pid == 42 ? "Visual Studio Code" : nil
            },
            processPath: { _ in "/usr/local/bin/node" },
            pathBasename: { ($0 as NSString).lastPathComponent }
        )
        let name = resolver.resolveDisplayName(pid: 42, fallbackCommand: "Code\\x20H")
        XCTAssertEqual(name, "Visual Studio Code")
    }

    func test_fallsBackToProcPidPathBasename() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in nil },
            processPath: { pid in
                pid == 99 ? "/Applications/Docker.app/Contents/MacOS/com.docker.backend" : nil
            },
            pathBasename: { ($0 as NSString).lastPathComponent }
        )
        let name = resolver.resolveDisplayName(pid: 99, fallbackCommand: "com.docke")
        XCTAssertEqual(name, "com.docker.backend")
    }

    func test_fallsBackToLsofCommand() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in nil },
            processPath: { _ in nil },
            pathBasename: { ($0 as NSString).lastPathComponent }
        )
        let name = resolver.resolveDisplayName(pid: 7, fallbackCommand: "node")
        XCTAssertEqual(name, "node")
    }

    func test_emptyRunningNameTreatedAsMiss() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in "   " },
            processPath: { _ in "/bin/zsh" },
            pathBasename: { ($0 as NSString).lastPathComponent }
        )
        // 空白 localizedName 不算命中，继续走 path basename
        let name = resolver.resolveDisplayName(pid: 1, fallbackCommand: "zsh")
        XCTAssertEqual(name, "zsh")
    }

    func test_emptyPathFallsThroughToCommand() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in nil },
            processPath: { _ in "" },
            pathBasename: { path in
                let base = (path as NSString).lastPathComponent
                return base
            }
        )
        let name = resolver.resolveDisplayName(pid: 3, fallbackCommand: "python3")
        XCTAssertEqual(name, "python3")
    }

    func test_emptyEverythingReturnsEmDash() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in nil },
            processPath: { _ in nil },
            pathBasename: { ($0 as NSString).lastPathComponent }
        )
        let name = resolver.resolveDisplayName(pid: 0, fallbackCommand: "  ")
        XCTAssertEqual(name, "—")
    }

    func test_pathBasenameInjection() {
        let resolver = ProcessNameResolver(
            runningAppName: { _ in nil },
            processPath: { _ in "/foo/bar/Custom Name" },
            pathBasename: { _ in "InjectedBase" }
        )
        XCTAssertEqual(resolver.resolveDisplayName(pid: 5, fallbackCommand: "cmd"), "InjectedBase")
    }
}
