import SwiftUI
import UserNotifications

/// `UNUserNotificationCenter` 只能在真正的 app bundle 进程中访问；`swift run` 的裸可执行文件会触发系统断言。
struct CleanerNotificationStatusGate {
    let bundleURL: URL

    /// 通知中心 API 依赖 app bundle；裸 SPM 可执行文件没有对应的 bundle proxy。
    var canAccessNotificationCenter: Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    func read(
        using reader: (@escaping (UNAuthorizationStatus) -> Void) -> Void,
        completion: @escaping (UNAuthorizationStatus) -> Void
    ) {
        guard canAccessNotificationCenter else { return }
        reader(completion)
    }
}

/// 垃圾清理器，为一眼而设计：一个完全选中、单击即就的安全区，以及一个默认不勾选、
/// 折叠收起、留给愿意深挖的人的可选区。每组都有通俗解释；逐文件细节在一个箭头之外而非眼前。
/// 作为 Settings 页面托管（全尺寸）。
struct CleanerView: View {
    let strings: Strings

    var body: some View {
        CleanerContentView(strings: strings, layout: .settings)
    }
}

/// 清理器共享内容。宽版与紧凑版只改变空间策略，始终观察同一个会话对象。
struct CleanerContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    let layout: UtilityContentLayout
    @ObservedObject var cleaner: JunkCleaner
    private let readNotificationStatus: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    private let notificationStatusGate: CleanerNotificationStatusGate
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var scheduler = CleanerScheduler.shared
    @AppStorage(UserDefaultsKeys.cleanerScheduleFrequency) private var scheduleFrequencyRaw = "off"
    @AppStorage(UserDefaultsKeys.cleanerScheduleHour) private var scheduleHour = 9
    @AppStorage(UserDefaultsKeys.cleanerScheduleMinute) private var scheduleMinute = 0
    @AppStorage(UserDefaultsKeys.cleanerScheduleWeekday) private var scheduleWeekday = 2
    @AppStorage(UserDefaultsKeys.cleanerLastAutoRun) private var lastAutoRun = 0.0
    @AppStorage(UserDefaultsKeys.cleanerLastAutoFreed) private var lastAutoFreed = 0
    @AppStorage(UserDefaultsKeys.cleanerScheduleNotify) private var scheduleNotify = true
    @State private var notificationsDenied = false

    init(
        strings: Strings,
        layout: UtilityContentLayout,
        cleaner: JunkCleaner = .shared,
        notificationStatusGate: CleanerNotificationStatusGate = CleanerNotificationStatusGate(
            bundleURL: Bundle.main.bundleURL
        ),
        readNotificationStatus: @escaping (@escaping (UNAuthorizationStatus) -> Void) -> Void = { completion in
            UNUserNotificationCenter.current().getNotificationSettings {
                completion($0.authorizationStatus)
            }
        }
    ) {
        self.strings = strings
        self.layout = layout
        self.cleaner = cleaner
        self.notificationStatusGate = notificationStatusGate
        self.readNotificationStatus = readNotificationStatus
    }

    var body: some View {
        content
            .frame(maxWidth: layout.contentWidth ?? .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch cleaner.phase {
        case .idle: idleState
        case .scanning: busyState(strings.cleanerScanning, detail: scanningDetail, canCancel: true)
        case .results: resultsState
        case .cleaning: busyState(strings.cleanerCleaning, detail: nil, canCancel: false)
        case let .done(freed, failed): doneState(freed: freed, failed: failed)
        }
    }

    /// 清理器的等待面孔：sparkles 图标通过系统符号效果逐层闪烁。无事发生时保持静止。
    private struct SparkleGlyph: View {
        var animating = false
        var size: CGFloat = 44

        var body: some View {
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative.reversing,
                              options: .repeating, isActive: animating)
        }
    }

    private var scanningDetail: String? {
        cleaner.scanningCategory.flatMap { category in
            DisplayGroup.allCases.first { $0.categories.contains(category) }
        }.map(title(for:))
    }

    private var scanningProgressText: String? {
        cleaner.scanProgress.map {
            String(
                format: strings.cleanerScanProgressFormat,
                $0.processedCandidates,
                $0.foundItems,
                Self.byteString($0.foundBytes)
            )
        }
    }

    // MARK: Display groups

    /// 原始发现的呈现方式：安全组在前、完全选中；判断调用在可选区、不勾选且折叠。
    private enum DisplayGroup: Int, CaseIterable, Identifiable {
        case loginItems, safeCaches, logs, developer
        case leftovers, otherCaches, deviceBackups, trash

        var id: Int { rawValue }

        var isSafe: Bool {
            switch self {
            case .loginItems, .safeCaches, .logs, .developer: return true
            case .leftovers, .otherCaches, .deviceBackups, .trash: return false
            }
        }

        var categories: [CleanerSupport.Category] {
            switch self {
            case .loginItems: return [.loginItems]
            case .safeCaches, .otherCaches: return [.caches]
            case .logs: return [.logs]
            case .developer: return [.developer]
            case .leftovers: return [.leftovers]
            case .deviceBackups: return [.deviceBackups]
            case .trash: return [.trash]
            }
        }

        var icon: String {
            switch self {
            case .loginItems: return "power"
            case .safeCaches: return "archivebox"
            case .logs: return "doc.text"
            case .developer: return "hammer"
            case .leftovers: return "puzzlepiece"
            case .otherCaches: return "internaldrive"
            case .deviceBackups: return "iphone"
            case .trash: return "trash"
            }
        }
    }

    private func items(for group: DisplayGroup) -> [JunkCleaner.Item] {
        switch group {
        case .safeCaches: return cleaner.items.filter { $0.category == .caches && $0.recommended }
        case .otherCaches: return cleaner.items.filter { $0.category == .caches && !$0.recommended }
        default: return cleaner.items.filter { group.categories.contains($0.category) }
        }
    }

    private func title(for group: DisplayGroup) -> String {
        switch group {
        case .loginItems: return strings.cleanerCatLoginItems
        case .safeCaches: return strings.cleanerCatCaches
        case .logs: return strings.cleanerCatLogs
        case .developer: return strings.cleanerCatDeveloper
        case .leftovers: return strings.cleanerCatLeftovers
        case .otherCaches: return strings.cleanerCatOtherCaches
        case .deviceBackups: return strings.cleanerCatDeviceBackups
        case .trash: return strings.cleanerCatTrash
        }
    }

    private func caption(for group: DisplayGroup) -> String {
        switch group {
        case .loginItems: return strings.cleanerLoginItemsCaption
        case .safeCaches: return strings.cleanerCachesCaption
        case .logs: return strings.cleanerLogsCaption
        case .developer: return strings.cleanerDeveloperCaption
        case .leftovers: return strings.cleanerLeftoversCaption
        case .otherCaches: return strings.cleanerOtherCachesCaption
        case .deviceBackups: return strings.cleanerDeviceBackupsCaption
        case .trash: return strings.cleanerTrashNote
        }
    }

    // MARK: Idle

    private var idleState: some View {
        VStack(spacing: 18) {
            Spacer()
            SparkleGlyph(size: 46)
            Text(strings.cleanerIntroTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(strings.cleanerIntroCaption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button(strings.cleanerScan) { cleaner.scan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            fullScheduleCard
            if !permissions.fullDiskAccess { fdaNote }
            Spacer()
        }
        .padding(layout.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: layout == .compact ? 420 : 480)
    }

    // MARK: Automatic cleanup

    private var scheduleFrequency: CleanerSchedule.Frequency {
        CleanerSchedule.Frequency.sanitized(scheduleFrequencyRaw)
    }

    /// 用户的时钟是 12 小时制（6 PM）还是 24 小时制（18:00）；选择器跟随 Mac 的设置。
    private static let uses12HourClock: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0,
                                              locale: Locale.current) ?? ""
        return format.contains("a")
    }()

    private static let dayPeriodSymbols: (am: String, pm: String) = {
        let formatter = DateFormatter()
        return (formatter.amSymbol ?? "AM", formatter.pmSymbol ?? "PM")
    }()

    /// 12 小时制选择器的存储小时拆分：小时、分钟、AM 或 PM。
    private var scheduleHour12Binding: Binding<Int> {
        Binding(
            get: { CleanerSchedule.hour12Components(fromHour24: scheduleHour).hour12 },
            set: { newValue in
                let isPM = CleanerSchedule.hour12Components(fromHour24: scheduleHour).isPM
                scheduleHour = CleanerSchedule.hour24(hour12: newValue, isPM: isPM)
            }
        )
    }

    private var schedulePMBinding: Binding<Bool> {
        Binding(
            get: { CleanerSchedule.hour12Components(fromHour24: scheduleHour).isPM },
            set: { isPM in
                let hour12 = CleanerSchedule.hour12Components(fromHour24: scheduleHour).hour12
                scheduleHour = CleanerSchedule.hour24(hour12: hour12, isPM: isPM)
            }
        )
    }

    /// 五分钟步进，加上存储值落在网格外时一并包含。
    private var minuteChoices: [Int] {
        var minutes = Array(stride(from: 0, through: 55, by: 5))
        if !minutes.contains(scheduleMinute), (0...59).contains(scheduleMinute) {
            minutes.append(scheduleMinute)
            minutes.sort()
        }
        return minutes
    }

    private static let nextRunFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var scheduleSummary: String {
        switch scheduleFrequency {
        case .off: return strings.cleanerScheduleOff
        case .daily: return strings.cleanerScheduleDaily
        case .weekly: return strings.cleanerScheduleWeekly
        }
    }

    private var frequencyPicker: some View {
        Picker("", selection: $scheduleFrequencyRaw) {
            Text(strings.cleanerScheduleOff).tag(CleanerSchedule.Frequency.off.rawValue)
            Text(strings.cleanerScheduleDaily).tag(CleanerSchedule.Frequency.daily.rawValue)
            Text(strings.cleanerScheduleWeekly).tag(CleanerSchedule.Frequency.weekly.rawValue)
        }
        .labelsHidden()
        .fixedSize()
    }

    /// 调度在一张小卡片里：一个频率，开启后是工作日和时间（纯菜单）、一行实时"下次清理"证明
    /// 调度已武装，以及带着权限状态开放的通知选项。
    @ViewBuilder
    private var fullScheduleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(strings.cleanerScheduleTitle)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                frequencyPicker
            }
            scheduleDetails
            Text(strings.cleanerScheduleCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: layout.dropTargetWidth)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04),
            radius: 6,
            x: 0,
            y: 1.5
        )
        .modifier(ScheduleChangeSync(notify: $scheduleNotify,
                                     frequency: $scheduleFrequencyRaw,
                                     refresh: refreshNotificationStatus,
                                     canAccessNotificationCenter: notificationStatusGate.canAccessNotificationCenter))
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        if scheduleFrequency != .off {
            HStack(spacing: 6) {
                if scheduleFrequency == .weekly {
                    Picker("", selection: $scheduleWeekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized)
                                .tag(day)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if Self.uses12HourClock {
                    Picker("", selection: scheduleHour12Binding) {
                        ForEach(1...12, id: \.self) { hour in
                            Text(String(hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Picker("", selection: $scheduleHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("", selection: $scheduleMinute) {
                    ForEach(minuteChoices, id: \.self) { minute in
                        Text(String(format: ":%02d", minute)).tag(minute)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if Self.uses12HourClock {
                    Picker("", selection: schedulePMBinding) {
                        Text(Self.dayPeriodSymbols.am).tag(false)
                        Text(Self.dayPeriodSymbols.pm).tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }
            Toggle(strings.cleanerScheduleNotifyToggle, isOn: $scheduleNotify)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            if scheduleNotify, notificationsDenied {
                Text(strings.cleanerNotifDenied)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(strings.cleanerNotifOpenSettings) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            if let next = scheduler.nextFire {
                Text(String(format: strings.cleanerScheduleNextFormat,
                            Self.nextRunFormatter.string(from: next)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if lastAutoRun > 0 {
                Text(lastRunLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 调度卡片的反应：保持调度器武装最新选择、opt-in 时请求通知权限，
    /// 并在 app 再次激活时（含从系统设置返回）重读权限。
    private struct ScheduleChangeSync: ViewModifier {
        @Binding var notify: Bool
        @Binding var frequency: String
        let refresh: () -> Void
        let canAccessNotificationCenter: Bool

        func body(content: Content) -> some View {
            content
                .onAppear { refresh() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    refresh()
                }
                .onChange(of: frequency) { _, _ in CleanerScheduler.shared.syncWithPreferences() }
                .onChange(of: notify) { _, wanted in
                    if wanted { requestNotificationPermission() }
                    refresh()
                }
        }

        private func requestNotificationPermission() {
            guard canAccessNotificationCenter else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private var lastRunLine: String {
        if lastAutoFreed > 0 {
            return String(format: strings.cleanerScheduleLastFormat,
                          Self.byteString(Int64(lastAutoFreed)))
        }
        let ranAt = Self.nextRunFormatter.string(from: Date(timeIntervalSince1970: lastAutoRun))
        return String(format: strings.cleanerScheduleRanFormat, ranAt)
    }

    /// 略微延迟检查，让刚弹出的授权提示有机会被回应后再出现警告。
    private func refreshNotificationStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            notificationStatusGate.read(using: readNotificationStatus) { status in
                DispatchQueue.main.async {
                    notificationsDenied = status == .denied
                }
            }
        }
    }

    private var fdaNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(strings.uninstallerFDANote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(strings.uninstallerFDAGrant) { permissions.requestFullDiskAccess() }
                Button(strings.uninstallerFDARelaunch) {
                    (NSApp.delegate as? AppDelegate)?.relaunchApp()
                }
            }
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: layout.dropTargetWidth)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04),
            radius: 6,
            x: 0,
            y: 1.5
        )
    }

    // MARK: Busy

    private func busyState(_ message: String, detail: String?, canCancel: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            SparkleGlyph(animating: true, size: 54)
            Text(message).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
            if canCancel, let progressText = scanningProgressText {
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let currentName = cleaner.scanProgress?.currentName {
                    Text(currentName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                }
            }
            if canCancel {
                Button(strings.uninstallerCancel) {
                    cleaner.cancelScan()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(SettingsAccessibilityID.cleanerCancelScan.rawValue)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: Results

    private var resultsState: some View {
        VStack(spacing: 0) {
            resultsHeader
            Divider()
            if cleaner.items.isEmpty, cleaner.scanFailures.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 24)
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.green)
                    Text(strings.cleanerNothingFound)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    if !cleaner.scanFailures.isEmpty {
                        Section(strings.toolFailed) {
                            ForEach(cleaner.scanFailures) { failure in
                                scanFailureRow(failure)
                            }
                        }
                    }
                    section(strings.cleanerSafeSection, groups: DisplayGroup.allCases.filter(\.isSafe))
                    section(strings.cleanerOptionalSection, groups: DisplayGroup.allCases.filter { !$0.isSafe })
                }
                .listStyle(.inset)
                .utilityResultsListHeight(layout)
                Divider()
                resultsFooter
            }
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 12) {
            SparkleGlyph(size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.cleanerName).font(.system(size: 15, weight: .semibold))
                Text("\(Self.byteString(cleaner.totalSize)) \(strings.uninstallerFoundTitle)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { cleaner.reset() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(layout == .compact ? 12 : 16)
    }

    @ViewBuilder
    private func section(_ header: String, groups: [DisplayGroup]) -> some View {
        let visible = groups.filter { !items(for: $0).isEmpty }
        if !visible.isEmpty {
            Section(header) {
                ForEach(visible) { group in groupRow(group) }
            }
        }
    }

    private func groupRow(_ group: DisplayGroup) -> some View {
        let groupItems = items(for: group)
        return DisclosureGroup {
            if group == .leftovers {
                Text(strings.cleanerLeftoversNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if group == .loginItems {
                Text(strings.cleanerLoginItemsNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(groupItems) { item in itemRow(item) }
        } label: {
            // 顶对齐：副标题换行时 checkbox / 图标仍贴标题行，避免相对整块内容垂直居中
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: groupBinding(group))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .padding(.top, 1)
                Image(systemName: group.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: group)).font(.system(size: 13, weight: .medium))
                    Text(caption(for: group))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Self.byteString(groupItems.reduce(0) { $0 + $1.size }))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.top, 1)
            }
            .padding(.vertical, 3)
        }
    }

    private func itemRow(_ item: JunkCleaner.Item) -> some View {
        // 与分组行一致：双行文案时 checkbox 贴名称行，不随路径行整体居中
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: includeBinding(item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(prettyPath(item.url))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(Self.byteString(item.size))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 1)
        }
        .padding(.leading, 8)
        .padding(.vertical, 1)
        .contextMenu {
            Button(strings.cleanerRevealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private var resultsFooter: some View {
        HStack {
            Text(String(format: strings.uninstallerSelectedFormat,
                        cleaner.selectedCount, cleaner.items.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(strings.uninstallerCancel) { cleaner.reset() }
            Button(String(format: strings.cleanerCleanSizeFormat,
                          Self.byteString(cleaner.selectedSize))) {
                cleaner.cleanSelected()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(cleaner.selectedCount == 0)
        }
        .padding(layout == .compact ? 12 : 16)
    }

    // MARK: Done

    private func doneState(freed: Int64, failed: Int) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: layout == .compact ? 42 : 54))
                    .foregroundStyle(failed == 0 ? Color.green : Color.orange)
                Text(strings.uninstallerDoneTitle).font(.system(size: 20, weight: .bold))
                Text(String(format: strings.uninstallerFreedFormat, Self.byteString(freed)))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(strings.cleanerDoneNote)
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                executionDetails

                HStack(spacing: 8) {
                    if !cleaner.failedItems.isEmpty {
                        Button(strings.toolRetryFailures) { cleaner.retryFailures() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(strings.cleanerAgain) { cleaner.reset() }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(layout.horizontalPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private var executionDetails: some View {
        if !cleaner.succeededItems.isEmpty || !cleaner.failedItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !cleaner.succeededItems.isEmpty {
                    resultSectionHeader(strings.toolSucceeded, count: cleaner.succeededItems.count, color: .green)
                    ForEach(cleaner.succeededItems) { item in
                        resultRow(name: item.name, path: item.url.path, message: nil)
                    }
                }
                if !cleaner.failedItems.isEmpty {
                    resultSectionHeader(strings.toolFailed, count: cleaner.failedItems.count, color: .orange)
                    ForEach(cleaner.failedItems) { failure in
                        resultRow(
                            name: failure.item.name,
                            path: failure.url.path,
                            message: failure.message
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }

    private func resultSectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.semibold))
            Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func resultRow(name: String, path: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scanFailureRow(_ failure: UtilityPathFailure) -> some View {
        Text(String(format: strings.toolScanFailure, failure.url.path, failure.message))
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private func includeBinding(_ item: JunkCleaner.Item) -> Binding<Bool> {
        Binding(
            get: { cleaner.items.first(where: { $0.id == item.id })?.include ?? false },
            set: { cleaner.setInclude($0, for: item.id) }
        )
    }

    private func groupBinding(_ group: DisplayGroup) -> Binding<Bool> {
        Binding(
            get: {
                let groupItems = items(for: group)
                return !groupItems.isEmpty && groupItems.allSatisfy(\.include)
            },
            set: { include in
                for item in items(for: group) {
                    cleaner.setInclude(include, for: item.id)
                }
            }
        )
    }

    private func prettyPath(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
