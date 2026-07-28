import AppKit
import XCTest
@testable import OmniForge

final class UtilitySessionTests: XCTestCase {
    func testCleanerPublishesMonotonicProgressWithExactSize() {
        let scanner = ProgressiveCleanerScanner(progresses: [
            CleanerScanProgress(
                category: .leftovers,
                processedCandidates: 1,
                foundItems: 0,
                foundBytes: 0,
                currentName: "a"
            ),
            CleanerScanProgress(
                category: .leftovers,
                processedCandidates: 2,
                foundItems: 1,
                foundBytes: 42,
                currentName: "b"
            ),
        ])
        let cleaner = JunkCleaner(scanner: scanner, fileOperator: RecordingFileOperator())

        cleaner.scan()
        waitUntil { cleaner.phase == .results }

        XCTAssertEqual(cleaner.scanProgress?.processedCandidates, 2)
        XCTAssertEqual(cleaner.scanProgress?.foundItems, 1)
        XCTAssertEqual(cleaner.scanProgress?.foundBytes, 42)
    }

    func testCleanerCancelDiscardsPartialResultsAndReturnsIdle() {
        let scanner = CancellableCleanerScanner()
        let cleaner = JunkCleaner(scanner: scanner, fileOperator: RecordingFileOperator())

        cleaner.scan()
        XCTAssertEqual(scanner.started.wait(timeout: .now() + 1), .success)
        cleaner.cancelScan()
        waitUntil { cleaner.phase == .idle }

        XCTAssertTrue(cleaner.items.isEmpty)
        XCTAssertTrue(cleaner.scanFailures.isEmpty)
        XCTAssertNil(cleaner.scanProgress)
    }

    func testCleanerPreservesPartialResultsAndRetriesOnlyFailures() {
        let first = cleanerItem("/tmp/omniforge/cache-a", size: 10)
        let second = cleanerItem("/tmp/omniforge/cache-b", size: 20)
        let scanError = UtilityPathFailure(
            url: URL(fileURLWithPath: "/tmp/unreadable"),
            message: "Permission denied"
        )
        let scanner = FakeCleanerScanner(result: .init(items: [first, second], failures: [scanError]))
        let operations = RecordingFileOperator { urls, attempt in
            if attempt == 0 {
                return urls.map {
                    $0 == first.url ? .success($0) : .failure($0, message: "Operation not permitted")
                }
            }
            return urls.map(UtilityFileOperationOutcome.success)
        }
        let cleaner = JunkCleaner(scanner: scanner, fileOperator: operations)

        cleaner.scan()
        waitUntil { cleaner.phase == .results }
        XCTAssertEqual(cleaner.scanFailures, [scanError])

        cleaner.cleanSelected()
        waitUntil { cleaner.phase == .done(freed: 10, failed: 1) }
        XCTAssertEqual(cleaner.succeededItems.map(\.url), [first.url])
        XCTAssertEqual(cleaner.failedItems.map(\.url), [second.url])
        XCTAssertEqual(cleaner.failedItems.first?.message, "Operation not permitted")
        XCTAssertEqual(cleaner.freedSpace, 10)

        cleaner.retryFailures()
        waitUntil { cleaner.phase == .done(freed: 30, failed: 0) }
        XCTAssertEqual(operations.calls, [[first.url, second.url], [second.url]])
        XCTAssertEqual(Set(cleaner.succeededItems.map(\.url)), Set([first.url, second.url]))
        XCTAssertTrue(cleaner.failedItems.isEmpty)
        XCTAssertEqual(cleaner.freedSpace, 30)

        cleaner.reset()
        XCTAssertEqual(cleaner.phase, .idle)
        XCTAssertTrue(cleaner.scanFailures.isEmpty)
        XCTAssertTrue(cleaner.succeededItems.isEmpty)
        XCTAssertTrue(cleaner.failedItems.isEmpty)
        XCTAssertEqual(cleaner.freedSpace, 0)
    }

    func testCleanerRejectsResetWhileScanIsBusy() {
        let scanner = BlockingCleanerScanner()
        let cleaner = JunkCleaner(scanner: scanner, fileOperator: RecordingFileOperator())

        cleaner.scan()
        XCTAssertEqual(scanner.started.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(cleaner.isBusy)
        XCTAssertFalse(cleaner.canReset)

        cleaner.reset()
        XCTAssertEqual(cleaner.phase, .scanning)

        scanner.resume.signal()
        waitUntil { cleaner.phase == .results }
        XCTAssertFalse(cleaner.isBusy)
        XCTAssertTrue(cleaner.canReset)
    }

    func testCleanerAllFailuresRemainAvailableForRetry() {
        let item = cleanerItem("/tmp/omniforge/cache-c", size: 12)
        let operations = RecordingFileOperator { urls, _ in
            urls.map { .failure($0, message: "Read-only file system") }
        }
        let cleaner = JunkCleaner(
            scanner: FakeCleanerScanner(result: .init(items: [item], failures: [])),
            fileOperator: operations
        )

        cleaner.scan()
        waitUntil { cleaner.phase == .results }
        cleaner.cleanSelected()
        waitUntil { cleaner.phase == .done(freed: 0, failed: 1) }

        XCTAssertTrue(cleaner.succeededItems.isEmpty)
        XCTAssertEqual(cleaner.failedItems.first?.url, item.url)
        XCTAssertEqual(cleaner.failedItems.first?.message, "Read-only file system")
    }

    func testCleanerRejectsResetWhileCleaning() {
        let item = cleanerItem("/tmp/omniforge/cache-d", size: 8)
        let operations = BlockingFileOperator()
        let cleaner = JunkCleaner(
            scanner: FakeCleanerScanner(result: .init(items: [item], failures: [])),
            fileOperator: operations
        )

        cleaner.scan()
        waitUntil { cleaner.phase == .results }
        cleaner.cleanSelected()
        XCTAssertEqual(operations.started.wait(timeout: .now() + 1), .success)

        cleaner.reset()
        XCTAssertEqual(cleaner.phase, .cleaning)
        XCTAssertFalse(cleaner.canReset)

        operations.resume.signal()
        waitUntil { cleaner.phase == .done(freed: 8, failed: 0) }
    }

    func testUninstallerPreservesPartialResultsAndRejectsReplacementWhileBusy() {
        let first = leftover("/tmp/InputLockOne.app", size: 40)
        let second = leftover("/tmp/InputLockSupport", size: 60)
        let target = uninstallTarget("/tmp/InputLockOne.app", name: "One")
        let replacement = uninstallTarget("/tmp/InputLockTwo.app", name: "Two")
        let scanner = FakeUninstallerScanner(result: .init(
            items: [first, second],
            failures: [UtilityPathFailure(url: URL(fileURLWithPath: "/tmp/private"), message: "Denied")]
        ))
        let operations = RecordingFileOperator { urls, attempt in
            if attempt == 0 {
                return urls.map {
                    $0 == first.url ? .success($0) : .failure($0, message: "Finder cancelled")
                }
            }
            return urls.map(UtilityFileOperationOutcome.success)
        }
        let uninstaller = AppUninstaller(scanner: scanner, fileOperator: operations)

        uninstaller.select(target: target)
        uninstaller.select(target: replacement)
        XCTAssertEqual(uninstaller.target?.url, target.url)
        XCTAssertTrue(uninstaller.isBusy)
        XCTAssertFalse(uninstaller.canReset)

        waitUntil { uninstaller.phase == .results }
        XCTAssertEqual(uninstaller.scanFailures.first?.message, "Denied")
        uninstaller.removeSelected()
        uninstaller.select(target: replacement)
        uninstaller.reset()
        XCTAssertEqual(uninstaller.target?.url, target.url)
        XCTAssertEqual(uninstaller.phase, .removing)
        waitUntil { uninstaller.phase == .done(freed: 40, failed: 1) }
        XCTAssertEqual(uninstaller.succeededItems.map(\.url), [first.url])
        XCTAssertEqual(uninstaller.failedItems.map(\.url), [second.url])

        uninstaller.retryFailures()
        waitUntil { uninstaller.phase == .done(freed: 100, failed: 0) }
        XCTAssertEqual(operations.calls, [[first.url, second.url], [second.url]])
        XCTAssertEqual(uninstaller.freedSpace, 100)

        uninstaller.reset()
        XCTAssertEqual(uninstaller.phase, .empty)
        XCTAssertNil(uninstaller.target)
        XCTAssertTrue(uninstaller.succeededItems.isEmpty)
    }

    func testDefaultCleanerScannerReportsDirectoryReadFailure() throws {
        let caches = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let reader = FailingFileReader(existing: [caches], directoryFailure: caches)

        let result = try DefaultJunkCleanerScanner(reader: reader).scan(
            progress: { _ in },
            cancellation: CleanerScanCancellation()
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.failures.map(\.url), [caches])
        XCTAssertEqual(result.failures.first?.message, "Permission denied")
    }

    func testDefaultCleanerScannerPublishesExactMonotonicProgress() throws {
        let caches = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let candidate = caches.appendingPathComponent("com.omniforgetests.definitely-uninstalled")
        let reader = ProgressFileReader(
            entriesByDirectory: [caches: [candidate]],
            sizes: [candidate: 42]
        )
        var progresses: [CleanerScanProgress] = []

        let result = try DefaultJunkCleanerScanner(reader: reader).scan(
            progress: { progresses.append($0) },
            cancellation: CleanerScanCancellation()
        )

        XCTAssertEqual(result.items.map(\.size), [42])
        XCTAssertTrue(zip(progresses, progresses.dropFirst()).allSatisfy { previous, current in
            previous.processedCandidates <= current.processedCandidates
                && previous.foundItems <= current.foundItems
                && previous.foundBytes <= current.foundBytes
        })
        XCTAssertEqual(progresses.last?.foundItems, 1)
        XCTAssertEqual(progresses.last?.foundBytes, 42)
    }

    func testDefaultUninstallerScannerReturnsFindingsAlongsideDirectoryReadFailure() {
        let target = uninstallTarget("/tmp/InputLockOne.app", name: "One")
        let preferences = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences")
        let reader = FailingFileReader(
            existing: [target.url, preferences],
            directoryFailure: preferences,
            sizes: [target.url: 40]
        )

        let result = DefaultAppUninstallerScanner(reader: reader).scan(target: target)

        XCTAssertEqual(result.items.map(\.url), [target.url])
        XCTAssertEqual(result.failures.map(\.url), [preferences])
        XCTAssertEqual(result.failures.first?.message, "Permission denied")
    }

    private func cleanerItem(_ path: String, size: Int64) -> JunkCleaner.Item {
        JunkCleaner.Item(
            url: URL(fileURLWithPath: path),
            category: .caches,
            size: size,
            detail: path,
            recommended: true
        )
    }

    private func leftover(_ path: String, size: Int64) -> AppUninstaller.Leftover {
        AppUninstaller.Leftover(
            url: URL(fileURLWithPath: path),
            category: .support,
            size: size
        )
    }

    private func uninstallTarget(_ path: String, name: String) -> AppUninstaller.Target {
        AppUninstaller.Target(
            name: name,
            bundleID: "com.example.\(name.lowercased())",
            url: URL(fileURLWithPath: path),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "等待异步状态超时", file: file, line: line)
    }
}

private final class FakeCleanerScanner: JunkCleanerScanning {
    let result: JunkCleaner.ScanResult

    init(result: JunkCleaner.ScanResult) {
        self.result = result
    }

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        progress(CleanerScanProgress(
            category: .caches,
            processedCandidates: 1,
            foundItems: result.items.count,
            foundBytes: result.items.reduce(0) { $0 + $1.size },
            currentName: result.items.first?.name
        ))
        return result
    }
}

private final class BlockingCleanerScanner: JunkCleanerScanning {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        started.signal()
        resume.wait()
        try cancellation.checkCancellation()
        return JunkCleaner.ScanResult(items: [], failures: [])
    }
}

private final class ProgressiveCleanerScanner: JunkCleanerScanning {
    let progresses: [CleanerScanProgress]

    init(progresses: [CleanerScanProgress]) {
        self.progresses = progresses
    }

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        for value in progresses {
            try cancellation.checkCancellation()
            progress(value)
        }
        return JunkCleaner.ScanResult(items: [], failures: [])
    }
}

private final class CancellableCleanerScanner: JunkCleanerScanning {
    let started = DispatchSemaphore(value: 0)

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        progress(CleanerScanProgress(
            category: .leftovers,
            processedCandidates: 1,
            foundItems: 1,
            foundBytes: 99,
            currentName: "partial"
        ))
        started.signal()
        while !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        try cancellation.checkCancellation()
        return JunkCleaner.ScanResult(items: [], failures: [])
    }
}

private final class FakeUninstallerScanner: AppUninstallerScanning {
    let result: AppUninstaller.ScanResult

    init(result: AppUninstaller.ScanResult) {
        self.result = result
    }

    func scan(target: AppUninstaller.Target) -> AppUninstaller.ScanResult {
        result
    }
}

private final class RecordingFileOperator: UtilityFileOperating {
    typealias MoveHandler = ([URL], Int) -> [UtilityFileOperationOutcome]

    private let lock = NSLock()
    private let moveHandler: MoveHandler
    private(set) var calls: [[URL]] = []

    init(moveHandler: @escaping MoveHandler = { urls, _ in
        urls.map(UtilityFileOperationOutcome.success)
    }) {
        self.moveHandler = moveHandler
    }

    func moveToTrash(_ urls: [URL]) -> [UtilityFileOperationOutcome] {
        lock.lock()
        let attempt = calls.count
        calls.append(urls)
        lock.unlock()
        return moveHandler(urls, attempt)
    }

    func emptyTrash(at url: URL) -> UtilityFileOperationOutcome {
        .success(url)
    }
}

private final class BlockingFileOperator: UtilityFileOperating {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func moveToTrash(_ urls: [URL]) -> [UtilityFileOperationOutcome] {
        started.signal()
        resume.wait()
        return urls.map(UtilityFileOperationOutcome.success)
    }

    func emptyTrash(at url: URL) -> UtilityFileOperationOutcome {
        .success(url)
    }
}

private final class FailingFileReader: UtilityFileReading {
    struct ReadError: LocalizedError {
        var errorDescription: String? { "Permission denied" }
    }

    private let existing: Set<URL>
    private let directoryFailure: URL
    private let sizes: [URL: Int64]

    init(existing: Set<URL>, directoryFailure: URL, sizes: [URL: Int64] = [:]) {
        self.existing = existing
        self.directoryFailure = directoryFailure
        self.sizes = sizes
    }

    func fileExists(at url: URL) -> Bool {
        existing.contains(url)
    }

    func isDirectory(at url: URL) throws -> Bool {
        true
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        if url == directoryFailure { throw ReadError() }
        return []
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        sizes[url] ?? 0
    }
}

private final class ProgressFileReader: UtilityFileReading {
    private let entriesByDirectory: [URL: [URL]]
    private let sizes: [URL: Int64]

    init(entriesByDirectory: [URL: [URL]], sizes: [URL: Int64]) {
        self.entriesByDirectory = entriesByDirectory
        self.sizes = sizes
    }

    func fileExists(at url: URL) -> Bool {
        entriesByDirectory[url] != nil || sizes[url] != nil
    }

    func isDirectory(at url: URL) throws -> Bool {
        entriesByDirectory[url] != nil
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        entriesByDirectory[url] ?? []
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        sizes[url] ?? 0
    }
}
