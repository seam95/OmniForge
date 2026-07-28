import AppKit
import Combine

/// 查找某 app 遗留的文件 —— 缓存、偏好、日志、支持目录、容器 ——
/// 把用户选中的项目移到废纸篓，然后报告释放的空间。所有操作都进废纸篓（可逆），
/// 绝不永久删除，因此流程始终安全。
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    enum Phase: Equatable {
        case empty
        case scanning
        case results
        case removing
        case done(freed: Int64, failed: Int)
    }

    struct Target: Equatable {
        let name: String
        let bundleID: String?
        let url: URL
        let icon: NSImage

        static func == (lhs: Target, rhs: Target) -> Bool { lhs.url == rhs.url }
    }

    enum Category: Int, CaseIterable {
        case app, support, caches, preferences, containers, logs, state, other

        var sortRank: Int { rawValue }
    }

    struct Leftover: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let category: Category
        let size: Int64
        var include: Bool = true

        var name: String { url.lastPathComponent }

        static func == (lhs: Leftover, rhs: Leftover) -> Bool {
            lhs.id == rhs.id && lhs.include == rhs.include
        }
    }

    struct ScanResult {
        let items: [Leftover]
        let failures: [UtilityPathFailure]
    }

    struct ItemFailure: Identifiable, Equatable {
        let item: Leftover
        let message: String

        var id: UUID { item.id }
        var url: URL { item.url }
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var target: Target?
    @Published var items: [Leftover] = []
    @Published private(set) var scanFailures: [UtilityPathFailure] = []
    @Published private(set) var succeededItems: [Leftover] = []
    @Published private(set) var failedItems: [ItemFailure] = []
    @Published private(set) var freedSpace: Int64 = 0

    private let scanner: any AppUninstallerScanning
    private let fileOperator: any UtilityFileOperating
    private let workerQueue: DispatchQueue

    init(scanner: any AppUninstallerScanning = DefaultAppUninstallerScanner(),
         fileOperator: any UtilityFileOperating = DefaultUtilityFileOperator(),
         workerQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        self.scanner = scanner
        self.fileOperator = fileOperator
        self.workerQueue = workerQueue
    }

    var selectedSize: Int64 { items.filter(\.include).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var succeededCount: Int { succeededItems.count }
    var isBusy: Bool { phase == .scanning || phase == .removing }
    var canReset: Bool { !isBusy }

    // MARK: - 选择与扫描

    /// 读取一个 app bundle 并开始扫描其遗留文件。
    func select(appURL: URL) {
        guard !isBusy else { return }
        guard let bundle = Bundle(url: appURL) else { return }
        // 系统 app 受 SIP 保护，其支持数据是活跃 OS 状态；移除任何一方都是错误的，因此拒绝选择。
        guard !appURL.standardizedFileURL.path.hasPrefix("/System") else { return }
        // bundle id 和 name 会成为扫描的路径组件。拒绝可能穿越出扫描根的值
        // （恶意 Info.plist 否则可能让用户文件夹看起来像遗留文件）。
        let bundleID = bundle.bundleIdentifier.flatMap { id in
            id.contains("/") || id.contains("..") ? nil : id
        }
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        if name.contains("/") || name.contains("..") { name = "" }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        select(target: Target(name: name, bundleID: bundleID, url: appURL, icon: icon))
    }

    func select(target: Target) {
        guard !isBusy else { return }
        guard !target.url.standardizedFileURL.path.hasPrefix("/System") else { return }
        guard target.bundleID.map({ !$0.contains("/") && !$0.contains("..") }) ?? true else { return }
        guard !target.name.contains("/"), !target.name.contains("..") else { return }
        self.target = target
        items = []
        scanFailures = []
        succeededItems = []
        failedItems = []
        freedSpace = 0
        phase = .scanning

        workerQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scanner.scan(target: target)
            DispatchQueue.main.async {
                // 用户在此扫描运行期间选了别的 app（或重置）时丢弃结果 ——
                // 绝不在 B 下面显示 A 的文件。
                guard self.phase == .scanning, self.target?.url == target.url else { return }
                self.items = result.items
                self.scanFailures = result.failures
                self.phase = .results
            }
        }
    }

    func setInclude(_ include: Bool, for id: UUID) {
        guard !isBusy else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].include = include
    }

    func reset() {
        guard canReset else { return }
        target = nil
        items = []
        scanFailures = []
        succeededItems = []
        failedItems = []
        freedSpace = 0
        phase = .empty
    }

    // MARK: - 移除

    func removeSelected() {
        guard phase == .results else { return }
        let chosen = items.filter(\.include)
        guard !chosen.isEmpty else { return }
        phase = .removing

        // 先退出运行中的副本，避免其文件被占用；terminate() 仍允许它提示保存。
        if let bundleID = target?.bundleID {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }

        execute(chosen, delay: 0.3)
    }

    func retryFailures() {
        guard !isBusy, !failedItems.isEmpty else { return }
        let retryItems = failedItems.map(\.item)
        failedItems = []
        phase = .removing
        execute(retryItems, delay: 0)
    }

    private func execute(_ chosen: [Leftover], delay: TimeInterval) {
        workerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let outcomes = self.fileOperator.moveToTrash(chosen.map(\.url))
            let outcomeByPath = Dictionary(uniqueKeysWithValues: outcomes.map {
                ($0.url.standardizedFileURL.path, $0)
            })
            let paired = chosen.map { item -> (Leftover, UtilityFileOperationOutcome) in
                let outcome = outcomeByPath[item.url.standardizedFileURL.path]
                    ?? .failure(item.url, message: "文件操作器未返回该路径的执行结果")
                return (item, outcome)
            }

            DispatchQueue.main.async {
                guard self.phase == .removing else { return }
                let successes = paired.filter { $0.1.errorMessage == nil }.map(\.0)
                self.succeededItems.append(contentsOf: successes)
                self.failedItems = paired.compactMap { item, outcome in
                    outcome.errorMessage.map { ItemFailure(item: item, message: $0) }
                }
                self.freedSpace += successes.reduce(0) { $0 + $1.size }
                self.phase = .done(freed: self.freedSpace, failed: self.failedItems.count)
            }
        }
    }

    // MARK: - 扫描

    static func performScan(target: Target, reader: any UtilityFileReading) -> ScanResult {
        let bundleID = target.bundleID
        let name = target.name
        let appURL = target.url
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        var paths: [(URL, Category)] = [(appURL, .app)]
        var failures: [UtilityPathFailure] = []

        func add(_ path: String, _ category: Category) {
            let url = URL(fileURLWithPath: path)
            if reader.fileExists(at: url) { paths.append((url, category)) }
        }
        func addMatches(in dir: String, _ category: Category, where matches: (String) -> Bool) {
            let directory = URL(fileURLWithPath: dir)
            guard reader.fileExists(at: directory) else { return }
            do {
                for entry in try reader.directoryEntries(at: directory) where matches(entry.lastPathComponent) {
                    paths.append((entry, category))
                }
            } catch {
                failures.append(UtilityPathFailure(url: directory, message: error.localizedDescription))
            }
        }

        if let id = bundleID {
            add("\(lib)/Application Support/\(id)", .support)
            add("\(lib)/Containers/\(id)", .containers)
            add("\(lib)/Caches/\(id)", .caches)
            add("\(lib)/Preferences/\(id).plist", .preferences)
            add("\(lib)/Saved Application State/\(id).savedState", .state)
            add("\(lib)/HTTPStorages/\(id)", .caches)
            add("\(lib)/HTTPStorages/\(id).binarycookies", .caches)
            add("\(lib)/WebKit/\(id)", .caches)
            add("\(lib)/Application Scripts/\(id)", .containers)
            add("\(lib)/Cookies/\(id).binarycookies", .caches)
            add("\(lib)/Logs/\(id)", .logs)
            addMatches(in: "\(lib)/Preferences/ByHost", .preferences) { matchesBundleScopedName($0, bundleID: id) }
            addMatches(in: "\(lib)/Preferences", .preferences) { $0.hasPrefix("\(id).") && $0 != "\(id).plist" }
            addMatches(in: "\(lib)/Group Containers", .containers) { matchesBundleScopedName($0, bundleID: id) }
            addMatches(in: "\(lib)/LaunchAgents", .other) { matchesBundleScopedName($0, bundleID: id) }
            // 系统位置（移到废纸篓可能需要管理员权限；失败会被上报）。
            add("/Library/Application Support/\(id)", .support)
            add("/Library/Caches/\(id)", .caches)
            add("/Library/Preferences/\(id).plist", .preferences)
            addMatches(in: "/Library/LaunchAgents", .other) { matchesBundleScopedName($0, bundleID: id) }
            addMatches(in: "/Library/LaunchDaemons", .other) { matchesBundleScopedName($0, bundleID: id) }
        }

        // 基于名称的目录，仅精确匹配：模糊匹配有风险。
        if !name.isEmpty {
            add("\(lib)/Application Support/\(name)", .support)
            add("\(lib)/Logs/\(name)", .logs)
            add("\(lib)/Caches/\(name)", .caches)
        }

        // 最后一道防线：扫描根（或 app bundle 自身）之外的任何东西都绝不能进入移除列表。
        let appPath = appURL.standardizedFileURL.path
        let allowedRoots = ["\(lib)/", "/Library/"]
        let safe = dedupe(paths).filter { url, _ in
            let path = url.standardizedFileURL.path
            return path == appPath || allowedRoots.contains { path.hasPrefix($0) && path != $0 }
        }
        let items = safe.compactMap { url, category -> Leftover? in
            do {
                return Leftover(url: url, category: category, size: try reader.allocatedSize(at: url))
            } catch {
                failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
                return nil
            }
        }
            .sorted { ($0.category.sortRank, -$0.size) < ($1.category.sortRank, -$1.size) }
        return ScanResult(items: items, failures: failures.deduplicatedByPathAndMessage())
    }

    static func matchesBundleScopedName(_ name: String, bundleID: String) -> Bool {
        if name == bundleID { return true }
        if name.hasPrefix("\(bundleID).") { return true }
        if name.hasSuffix(".\(bundleID)") { return true }
        if name.contains(".\(bundleID).") { return true }
        let groupName = "group.\(bundleID)"
        return name == groupName || name.hasPrefix("\(groupName).")
    }

    /// 去除精确重复，以及嵌套在另一个已发现路径内的任何路径。
    static func dedupe(_ paths: [(URL, Category)]) -> [(URL, Category)] {
        var seen = Set<String>()
        var roots: [String] = []
        var out: [(URL, Category)] = []
        for (url, category) in paths.sorted(by: { $0.0.path.count < $1.0.path.count }) {
            let path = url.standardizedFileURL.path
            if seen.contains(path) { continue }
            if roots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            seen.insert(path)
            roots.append(path)
            out.append((url, category))
        }
        return out
    }

}

protocol AppUninstallerScanning {
    func scan(target: AppUninstaller.Target) -> AppUninstaller.ScanResult
}

final class DefaultAppUninstallerScanner: AppUninstallerScanning {
    private let reader: any UtilityFileReading

    init(reader: any UtilityFileReading = DefaultUtilityFileReader()) {
        self.reader = reader
    }

    func scan(target: AppUninstaller.Target) -> AppUninstaller.ScanResult {
        AppUninstaller.performScan(target: target, reader: reader)
    }
}
