import AppKit
import Combine

struct CleanerScanProgress: Equatable {
    let category: CleanerSupport.Category
    let processedCandidates: Int
    let foundItems: Int
    let foundBytes: Int64
    let currentName: String?
}

final class CleanerScanCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

private final class CleanerScanProgressReporter {
    private let publish: (CleanerScanProgress) -> Void
    private var category: CleanerSupport.Category = .leftovers
    private var processedCandidates = 0
    private var foundItems = 0
    private var foundBytes: Int64 = 0
    private var currentName: String?

    init(publish: @escaping (CleanerScanProgress) -> Void) {
        self.publish = publish
    }

    func begin(_ category: CleanerSupport.Category) {
        self.category = category
        currentName = nil
        emit()
    }

    func willMeasure(_ url: URL) {
        processedCandidates += 1
        currentName = url.lastPathComponent
        emit()
    }

    func didFind(_ items: [JunkCleaner.Item]) {
        foundItems += items.count
        foundBytes += items.reduce(Int64(0)) { $0 + $1.size }
        emit()
    }

    private func emit() {
        publish(CleanerScanProgress(
            category: category,
            processedCandidates: processedCandidates,
            foundItems: foundItems,
            foundBytes: foundBytes,
            currentName: currentName
        ))
    }
}

private final class CleanerTrackingFileReader: UtilityFileReading {
    private let base: any UtilityFileReading
    private let reporter: CleanerScanProgressReporter
    private let cancellation: CleanerScanCancellation

    init(
        base: any UtilityFileReading,
        reporter: CleanerScanProgressReporter,
        cancellation: CleanerScanCancellation
    ) {
        self.base = base
        self.reporter = reporter
        self.cancellation = cancellation
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func isDirectory(at url: URL) throws -> Bool {
        try cancellation.checkCancellation()
        return try base.isDirectory(at: url)
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        try cancellation.checkCancellation()
        let entries = try base.directoryEntries(at: url)
        try cancellation.checkCancellation()
        return entries
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        try allocatedSize(at: url, cancellation: cancellation)
    }

    func allocatedSize(at url: URL, cancellation: CleanerScanCancellation) throws -> Int64 {
        reporter.willMeasure(url)
        return try base.allocatedSize(at: url, cancellation: cancellation)
    }
}

/// 查找 Mac 积累的垃圾 —— 已卸载 app 的残留、孤儿启动项、缓存、日志、开发者构建垃圾、废纸篓 ——
/// 让用户逐条审查每个路径及其大小，确认后把选中项移到废纸篓。扫描期间绝不触碰任何文件，
/// 用户打开工具前绝不运行任何东西。
///
/// 安全模型（按重要性排序）：
/// 1. 先审查。每项在发生任何事之前都展示完整路径和大小，不确定的发现默认不勾选。
/// 2. 进废纸篓，而非删除。每次移除都是可逆的到废纸篓移动（Trash 类别本身是唯一的明确例外）。
/// 3. 绝不对活跃 app 猜测。残留需要 bundle 形状的名称，其 owner 未安装、未运行、非 Apple、
///    且与任何已安装 id 无关（点边界家族匹配）。
/// 4. 仅限范围内根。项目来自固定的、已知的垃圾位置，仅一层深；范围之外的东西永不出现。
final class JunkCleaner: ObservableObject {
    static let shared = JunkCleaner()

    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case done(freed: Int64, failed: Int)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let category: CleanerSupport.Category
        let size: Int64
        /// 简短的次要行：所属 bundle id 或标签。
        let detail: String
        /// 此发现是否足够安全到无需二次审视即可清理。推荐项默认选中并位于安全区；其余默认不勾选。
        let recommended: Bool
        var include: Bool

        var name: String { url.lastPathComponent }

        init(url: URL, category: CleanerSupport.Category, size: Int64,
             detail: String, recommended: Bool) {
            self.url = url
            self.category = category
            self.size = size
            self.detail = detail
            self.recommended = recommended
            self.include = recommended
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.include == rhs.include
        }
    }

    struct ScanResult {
        let items: [Item]
        let failures: [UtilityPathFailure]
    }

    struct ItemFailure: Identifiable, Equatable {
        let item: Item
        let message: String

        var id: UUID { item.id }
        var url: URL { item.url }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var items: [Item] = []
    /// 当前正在扫描的类别，用于进度行。
    @Published private(set) var scanningCategory: CleanerSupport.Category?
    @Published private(set) var scanProgress: CleanerScanProgress?
    @Published private(set) var scanFailures: [UtilityPathFailure] = []
    @Published private(set) var succeededItems: [Item] = []
    @Published private(set) var failedItems: [ItemFailure] = []
    @Published private(set) var freedSpace: Int64 = 0

    private let scanner: any JunkCleanerScanning
    private let fileOperator: any UtilityFileOperating
    private let workerQueue: DispatchQueue
    private var scanCancellation: CleanerScanCancellation?

    init(scanner: any JunkCleanerScanning = DefaultJunkCleanerScanner(),
         fileOperator: any UtilityFileOperating = DefaultUtilityFileOperator(),
         workerQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        self.scanner = scanner
        self.fileOperator = fileOperator
        self.workerQueue = workerQueue
    }

    var selectedSize: Int64 { items.filter(\.include).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.include).count }
    var succeededCount: Int { succeededItems.count }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }
    var canReset: Bool { !isBusy }

    func items(in category: CleanerSupport.Category) -> [Item] {
        items.filter { $0.category == category }
    }

    func setInclude(_ include: Bool, for id: UUID) {
        guard !isBusy else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].include = include
    }

    func setInclude(_ include: Bool, forCategory category: CleanerSupport.Category) {
        guard !isBusy else { return }
        for index in items.indices where items[index].category == category {
            items[index].include = include
        }
    }

    func reset() {
        guard canReset else { return }
        items = []
        scanningCategory = nil
        scanProgress = nil
        scanFailures = []
        succeededItems = []
        failedItems = []
        freedSpace = 0
        phase = .idle
    }

    // MARK: - 扫描

    func scan() {
        guard !isBusy else { return }
        items = []
        scanningCategory = nil
        scanProgress = nil
        scanFailures = []
        succeededItems = []
        failedItems = []
        freedSpace = 0
        phase = .scanning
        let cancellation = CleanerScanCancellation()
        scanCancellation = cancellation

        workerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.scanner.scan(progress: { [weak self] progress in
                    DispatchQueue.main.async {
                        guard let self, self.phase == .scanning else { return }
                        self.scanningCategory = progress.category
                        self.scanProgress = progress
                    }
                }, cancellation: cancellation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .scanning else { return }
                    self.items = result.items
                    self.scanFailures = result.failures
                    self.scanningCategory = nil
                    self.scanCancellation = nil
                    self.phase = .results
                }
            } catch is CancellationError {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .scanning else { return }
                    self.items = []
                    self.scanFailures = []
                    self.scanningCategory = nil
                    self.scanProgress = nil
                    self.scanCancellation = nil
                    self.phase = .idle
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .scanning else { return }
                    self.items = []
                    self.scanFailures = [UtilityPathFailure(
                        url: URL(fileURLWithPath: NSHomeDirectory()),
                        message: error.localizedDescription
                    )]
                    self.scanningCategory = nil
                    self.scanCancellation = nil
                    self.phase = .results
                }
            }
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        scanCancellation?.cancel()
    }

    // MARK: - 清理

    func cleanSelected() {
        guard phase == .results else { return }
        let chosen = items.filter(\.include)
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        execute(chosen)
    }

    func retryFailures() {
        guard !isBusy, !failedItems.isEmpty else { return }
        let retryItems = failedItems.map(\.item)
        failedItems = []
        phase = .cleaning
        execute(retryItems)
    }

    private func execute(_ chosen: [Item]) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            var outcomes: [(Item, UtilityFileOperationOutcome)] = []

            // 废纸篓必须先清空，避免本轮随后移入废纸篓的可恢复项目被永久删除。
            for item in chosen where item.category == .trash {
                outcomes.append((item, self.fileOperator.emptyTrash(at: item.url)))
            }

            let removable = chosen.filter { $0.category != .trash && Self.mayRemove($0.url) }
            let unsafe = chosen.filter { $0.category != .trash && !Self.mayRemove($0.url) }
            for item in removable where item.category == .loginItems {
                Self.bootoutUserAgent(item.url)
            }
            let moved = self.fileOperator.moveToTrash(removable.map(\.url))
            let outcomeByPath = Dictionary(uniqueKeysWithValues: moved.map { ($0.url.standardizedFileURL.path, $0) })
            outcomes.append(contentsOf: removable.map { item in
                let outcome = outcomeByPath[item.url.standardizedFileURL.path]
                    ?? .failure(item.url, message: "文件操作器未返回该路径的执行结果")
                return (item, outcome)
            })
            outcomes.append(contentsOf: unsafe.map {
                ($0, .failure($0.url, message: "路径未通过清理安全检查"))
            })

            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .cleaning else { return }
                let successes = outcomes.filter { $0.1.errorMessage == nil }.map(\.0)
                let failures = outcomes.compactMap { item, outcome in
                    outcome.errorMessage.map { ItemFailure(item: item, message: $0) }
                }
                self.succeededItems.append(contentsOf: successes)
                self.failedItems = failures
                self.freedSpace += successes.reduce(0) { $0 + $1.size }
                self.phase = .done(freed: self.freedSpace, failed: self.failedItems.count)
            }
        }
    }

    /// 精确匹配守卫，即便扫描器 bug 产生了临界根也绝不移除。项目已按构造限定范围；
    /// 这是最后一道防线。
    private static func mayRemove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        let critical: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/usr",
            "/bin", "/sbin", "/etc", "/var", "/private", "/opt",
            home, home + "/Library", home + "/Documents", home + "/Desktop",
            home + "/Downloads", home + "/Pictures", home + "/Music", home + "/Movies",
        ]
        guard !critical.contains(path) else { return false }
        // 深度守卫：这么浅的东西都是某种根，绝非垃圾。
        return url.pathComponents.count >= 4
    }

    /// 在 plist 进废纸篓前卸载用户 launch agent，使任务不会运行到登出。尽力而为：
    /// 从未加载的 plist 只会让 launchctl 非零退出，这没问题。
    private static func bootoutUserAgent(_ plistURL: URL) {
        guard plistURL.path.hasPrefix(NSHomeDirectory() + "/Library/LaunchAgents/") else { return }
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty,
              !label.contains("/"), !label.contains("..") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        // 从未加载的 plist 会让 launchctl 抱怨；这是预期的，不值得在任何人控制台留一行。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - 已安装 app 预言机

    /// 每个必须被视为活跃的 bundle id：在应用程序文件夹中找到的 app（三层深，覆盖子文件夹和套件）、
    /// 当前运行的一切、以及嵌套在这些 app 内的登录项 helper。
    static func installedBundleIDs() -> Set<String> {
        var failures: [UtilityPathFailure] = []
        return installedBundleIDs(
            reader: DefaultUtilityFileReader(),
            failures: &failures,
            cancellation: nil
        )
    }

    private static func installedBundleIDs(reader: any UtilityFileReading,
                                           failures: inout [UtilityPathFailure],
                                           cancellation: CleanerScanCancellation?) -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications", "/System/Applications",
                     NSHomeDirectory() + "/Applications"]

        func collect(at url: URL, depth: Int) {
            guard depth > 0 else { return }
            guard reader.fileExists(at: url) else { return }
            let entries: [URL]
            do {
                entries = try reader.directoryEntries(at: url)
            } catch {
                failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
                return
            }
            for entry in entries {
                guard cancellation?.isCancelled != true else { return }
                if entry.pathExtension == "app" {
                    if let id = Bundle(url: entry)?.bundleIdentifier {
                        ids.insert(id.lowercased())
                    }
                    // 登录项 helper 驻留在 app 内，以自己的 id 持有 launch plist。
                    collect(at: entry.appendingPathComponent("Contents/Library/LoginItems"), depth: 1)
                } else {
                    do {
                        guard try reader.isDirectory(at: entry) else { continue }
                    } catch {
                        failures.append(UtilityPathFailure(url: entry, message: error.localizedDescription))
                        continue
                    }
                    collect(at: entry, depth: depth - 1)
                }
            }
        }

        for root in roots {
            guard cancellation?.isCancelled != true else { break }
            collect(at: URL(fileURLWithPath: root), depth: 3)
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        return ids
    }

    static func performScan(
        reader: any UtilityFileReading,
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> ScanResult {
        let reporter = CleanerScanProgressReporter(publish: progress)
        let trackedReader = CleanerTrackingFileReader(
            base: reader,
            reporter: reporter,
            cancellation: cancellation
        )
        var failures: [UtilityPathFailure] = []
        reporter.begin(.leftovers)
        let installed = installedBundleIDs(
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        try cancellation.checkCancellation()
        var items: [Item] = []
        var claimed = Set<String>()

        let leftovers = scanLeftovers(
            installed: installed,
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: leftovers)
        claimed.formUnion(leftovers.map { $0.url.standardizedFileURL.path })
        reporter.didFind(leftovers)
        try cancellation.checkCancellation()

        reporter.begin(.loginItems)
        let loginItems = scanOrphanedLaunchPlists(
            installed: installed,
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: loginItems)
        reporter.didFind(loginItems)
        try cancellation.checkCancellation()

        reporter.begin(.caches)
        let caches = scanCaches(
            excluding: claimed,
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: caches)
        reporter.didFind(caches)
        try cancellation.checkCancellation()

        reporter.begin(.logs)
        let logs = scanLogs(
            excluding: claimed,
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: logs)
        reporter.didFind(logs)
        try cancellation.checkCancellation()

        reporter.begin(.developer)
        let developer = scanDeveloperJunk(
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: developer)
        reporter.didFind(developer)
        try cancellation.checkCancellation()

        reporter.begin(.trash)
        let trash = scanTrash(
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: trash)
        reporter.didFind(trash)
        try cancellation.checkCancellation()

        reporter.begin(.deviceBackups)
        let backups = scanDeviceBackups(
            reader: trackedReader,
            failures: &failures,
            cancellation: cancellation
        )
        items.append(contentsOf: backups)
        reporter.didFind(backups)
        try cancellation.checkCancellation()
        return ScanResult(items: items, failures: failures.deduplicatedByPathAndMessage())
    }

    /// 候选 id 是否有活跃 owner 的最终裁决：收集集合（家族匹配）、厂商命名空间规则
    /// （套件和更新器与 sibling id 共享命名空间）、以及 Launch Services（知道磁盘上任何位置注册的 app）。
    private static func hasLivingOwner(_ candidate: String, installed: Set<String>) -> Bool {
        if CleanerSupport.isOwned(candidate: candidate, byInstalled: installed) { return true }
        if CleanerSupport.sharesVendorNamespace(candidate: candidate, withInstalled: installed) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil
    }

    // MARK: - 类别扫描器

    /// 已卸载 app 留下数据的用户域位置。一层深；每个条目必须映射到 bundle id 才会被考虑
    /// （纯厂商目录永不按名猜测）。Group Containers 和 Application Scripts 故意缺席：
    /// 它们 team 前缀的、跨 app 的名称无法安全归因。
    private static let leftoverRoots: [String] = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs",
        "Containers", "Cookies",
    ]

    private static func scanLeftovers(installed: Set<String>, reader: any UtilityFileReading,
                                      failures: inout [UtilityPathFailure],
                                      cancellation: CleanerScanCancellation) -> [Item] {
        let lib = NSHomeDirectory() + "/Library"
        var found: [Item] = []
        for root in leftoverRoots {
            guard !cancellation.isCancelled else { break }
            let dir = URL(fileURLWithPath: lib + "/" + root)
            for url in entries(at: dir, reader: reader, failures: &failures) {
                guard !cancellation.isCancelled else { break }
                let entry = url.lastPathComponent
                var candidate = CleanerSupport.bundleIDCandidate(fromEntryName: entry)
                if candidate == nil, root == "Containers" {
                    // 现代容器带不透明 UUID 名；owner 记录在容器元数据中。
                    candidate = containerOwner(at: url, reader: reader, failures: &failures)
                }
                guard let owner = candidate,
                      !CleanerSupport.isProtectedBundleID(owner),
                      !hasLivingOwner(owner, installed: installed) else { continue }
                guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
                found.append(Item(url: url, category: .leftovers,
                                  size: size,
                                  detail: owner,
                                  recommended: CleanerPolicy.precheckLeftovers))
            }
        }
        return sorted(found)
    }

    /// 容器文件夹的所属 bundle id，取自容器管理器在其中写入的元数据。
    private static func containerOwner(at url: URL, reader: any UtilityFileReading,
                                       failures: inout [UtilityPathFailure]) -> String? {
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard reader.fileExists(at: metadata) else { return nil }
        let dict: [String: Any]
        do {
            let data = try Data(contentsOf: metadata)
            guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else {
                failures.append(UtilityPathFailure(url: metadata, message: "属性列表根对象不是字典"))
                return nil
            }
            dict = parsed
        } catch {
            failures.append(UtilityPathFailure(url: metadata, message: error.localizedDescription))
            return nil
        }
        guard
              let owner = dict["MCMMetadataIdentifier"] as? String,
              CleanerSupport.looksLikeBundleID(owner) else { return nil }
        return owner
    }

    /// 所有引用的可执行文件均已失活、且 label 无活跃 owner 的 launch agent 和 daemon：
    /// 经典幽灵，让已删除 app 仍出现在「登录项与扩展」下。
    private static func scanOrphanedLaunchPlists(installed: Set<String>, reader: any UtilityFileReading,
                                                 failures: inout [UtilityPathFailure],
                                                 cancellation: CleanerScanCancellation) -> [Item] {
        let roots = [NSHomeDirectory() + "/Library/LaunchAgents",
                     "/Library/LaunchAgents",
                     "/Library/LaunchDaemons"]
        var found: [Item] = []
        for root in roots {
            guard !cancellation.isCancelled else { break }
            let rootURL = URL(fileURLWithPath: root)
            for url in entries(at: rootURL, reader: reader, failures: &failures)
                where url.pathExtension == "plist" {
                guard !cancellation.isCancelled else { break }
                let entry = url.lastPathComponent
                let plist: [String: Any]
                do {
                    let data = try Data(contentsOf: url)
                    guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any] else {
                        failures.append(UtilityPathFailure(url: url, message: "属性列表根对象不是字典"))
                        continue
                    }
                    plist = parsed
                } catch {
                    failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
                    continue
                }
                let label = plist["Label"] as? String
                let executables = CleanerSupport.executablePaths(inLaunchPlist: plist)
                guard CleanerSupport.launchPlistIsRemovableOrphan(
                    label: label,
                    executables: executables,
                    // 外部卷上缺失的二进制是不确定的（卷可能只是未挂载），因此算作存在，plist 保留。
                    executableExists: { $0.hasPrefix("/Volumes/")
                        || reader.fileExists(at: URL(fileURLWithPath: $0)) }) else { continue }
                // 第二信号：label 本身也不得属于任何已安装的东西（移动的二进制不是已卸载的 app）。
                if let label, hasLivingOwner(label, installed: installed) { continue }
                guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
                found.append(Item(url: url, category: .loginItems,
                                  size: size,
                                  detail: label ?? entry,
                                  recommended: CleanerPolicy.precheckLoginItems))
            }
        }
        return sorted(found)
    }

    private static func scanCaches(excluding claimed: Set<String>, reader: any UtilityFileReading,
                                   failures: inout [UtilityPathFailure],
                                   cancellation: CleanerScanCancellation) -> [Item] {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        var found: [Item] = []
        for url in entries(at: dir, reader: reader, failures: &failures) {
            guard !cancellation.isCancelled else { break }
            let entry = url.lastPathComponent
            guard !CleanerPolicy.isExcludedCacheEntry(entry) else { continue }
            guard !claimed.contains(url.standardizedFileURL.path) else { continue }
            guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
            guard size > 0 else { continue }
            found.append(Item(url: url, category: .caches, size: size,
                              detail: entry,
                              recommended: CleanerPolicy.precheckCacheEntry(entry)))
        }
        return sorted(found)
    }

    private static func scanLogs(excluding claimed: Set<String>, reader: any UtilityFileReading,
                                 failures: inout [UtilityPathFailure],
                                 cancellation: CleanerScanCancellation) -> [Item] {
        var found: [Item] = []
        let logsDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs")
        for url in entries(at: logsDir, reader: reader, failures: &failures) {
            guard !cancellation.isCancelled else { break }
            let entry = url.lastPathComponent
            if entry != "DiagnosticReports"
                && !entry.hasPrefix(".")
                && !CleanerPolicy.isExcludedCacheEntry(entry) {
                guard !claimed.contains(url.standardizedFileURL.path) else { continue }
                guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
                guard size > 0 else { continue }
                found.append(Item(url: url, category: .logs, size: size,
                                  detail: entry, recommended: CleanerPolicy.precheckLogs))
            }
        }
        let reportsURL = logsDir.appendingPathComponent("DiagnosticReports")
        if let reportsSize = size(of: reportsURL, reader: reader, failures: &failures), reportsSize > 0 {
            found.append(Item(url: reportsURL, category: .logs, size: reportsSize,
                              detail: "DiagnosticReports", recommended: CleanerPolicy.precheckLogs))
        }
        return sorted(found)
    }

    private static func scanDeveloperJunk(reader: any UtilityFileReading,
                                          failures: inout [UtilityPathFailure],
                                          cancellation: CleanerScanCancellation) -> [Item] {
        var found: [Item] = []
        for path in CleanerPolicy.developerJunkPaths {
            guard !cancellation.isCancelled else { break }
            let url = URL(fileURLWithPath: NSHomeDirectory() + path)
            guard reader.fileExists(at: url) else { continue }
            guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
            guard size > 0 else { continue }
            found.append(Item(url: url, category: .developer, size: size,
                              detail: url.lastPathComponent,
                              recommended: CleanerPolicy.precheckDeveloper))
        }
        return sorted(found)
    }

    /// MobileSync 下的旧 iPhone 和 iPad 备份：与缓存一起，是 macOS「其他」存储的另一个经典租户。
    /// 它们是用户的安全网，因此每个发现默认不勾选并标明设备和备份日期。无完全磁盘访问权限时
    /// 文件夹不可读，不提供任何东西。
    private static func scanDeviceBackups(reader: any UtilityFileReading,
                                          failures: inout [UtilityPathFailure],
                                          cancellation: CleanerScanCancellation) -> [Item] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MobileSync/Backup")
        var found: [Item] = []
        for url in entries(at: root, reader: reader, failures: &failures) {
            guard !cancellation.isCancelled else { break }
            let entry = url.lastPathComponent
            do {
                guard try reader.isDirectory(at: url) else { continue }
            } catch {
                failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
                continue
            }
            guard let size = size(of: url, reader: reader, failures: &failures) else { continue }
            guard size > 0 else { continue }
            let infoURL = url.appendingPathComponent("Info.plist")
            var info: [String: Any]?
            if reader.fileExists(at: infoURL) {
                do {
                    let data = try Data(contentsOf: infoURL)
                    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                    if let parsed = value as? [String: Any] {
                        info = parsed
                    } else {
                        failures.append(UtilityPathFailure(url: infoURL, message: "属性列表根对象不是字典"))
                    }
                } catch {
                    failures.append(UtilityPathFailure(url: infoURL, message: error.localizedDescription))
                }
            }
            let device = info?["Device Name"] as? String
            let date = (info?["Last Backup Date"] as? Date).map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
            }
            let detail = [device, date].compactMap { $0 }.joined(separator: ", ")
            found.append(Item(url: url, category: .deviceBackups, size: size,
                              detail: detail.isEmpty ? entry : detail,
                              recommended: CleanerPolicy.precheckDeviceBackups))
        }
        return sorted(found)
    }

    private static func scanTrash(reader: any UtilityFileReading,
                                  failures: inout [UtilityPathFailure],
                                  cancellation: CleanerScanCancellation) -> [Item] {
        let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        // 只计用户在废纸篓中能看到的：空废纸篓仍携带隐藏簿记文件（.DS_Store），
        // 提供清空那些读起来像谎言。
        let visible = entries(at: trash, reader: reader, failures: &failures)
        guard !visible.isEmpty else { return [] }
        var totalSize: Int64 = 0
        for url in visible {
            guard !cancellation.isCancelled else { break }
            guard let itemSize = size(of: url, reader: reader, failures: &failures) else { continue }
            totalSize += itemSize
        }
        guard totalSize > 0 else { return [] }
        return [Item(url: trash, category: .trash, size: totalSize,
                     detail: "", recommended: false)]
    }

    // MARK: - 辅助

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { $0.size > $1.size }
    }

    private static func entries(at url: URL, reader: any UtilityFileReading,
                                failures: inout [UtilityPathFailure]) -> [URL] {
        guard reader.fileExists(at: url) else { return [] }
        do {
            return try reader.directoryEntries(at: url)
        } catch {
            failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
            return []
        }
    }

    private static func size(of url: URL, reader: any UtilityFileReading,
                             failures: inout [UtilityPathFailure]) -> Int64? {
        guard reader.fileExists(at: url) else { return nil }
        do {
            return try reader.allocatedSize(at: url)
        } catch {
            failures.append(UtilityPathFailure(url: url, message: error.localizedDescription))
            return nil
        }
    }
}

protocol JunkCleanerScanning {
    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult
}

final class DefaultJunkCleanerScanner: JunkCleanerScanning {
    private let reader: any UtilityFileReading

    init(reader: any UtilityFileReading = DefaultUtilityFileReader()) {
        self.reader = reader
    }

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        try JunkCleaner.performScan(
            reader: reader,
            progress: progress,
            cancellation: cancellation
        )
    }
}
