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

    /// 品牌色：与实用工具列表行的清理徽章一致。
    private var tint: Color { UtilityTool.cleaner.tintColor }

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
        var tint: Color = .secondary

        var body: some View {
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(tint)
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
                UtilityKit.byteString($0.foundBytes)
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
        VStack(spacing: 16) {
            Spacer()
            UtilityGlyphTile(symbol: "sparkles", tint: tint, size: 56)
            VStack(spacing: 6) {
                Text(strings.cleanerIntroTitle)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Text(strings.cleanerIntroCaption)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            Button(strings.cleanerScan) { cleaner.scan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(tint)
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
                UtilityGlyphTile(symbol: "clock", tint: tint, size: 26, symbolSize: 12)
                Text(strings.cleanerScheduleTitle)
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Spacer()
                frequencyPicker
            }
            scheduleDetails
            Text(strings.cleanerScheduleCaption)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: layout.dropTargetWidth)
        .utilityCardBackground()
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
                          UtilityKit.byteString(Int64(lastAutoFreed)))
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
        .padding(12)
        .frame(maxWidth: layout.dropTargetWidth)
        .utilityInsetBackground()
    }

    // MARK: Busy

    private func busyState(_ message: String, detail: String?, canCancel: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            SparkleGlyph(animating: true, size: 54, tint: tint)
            Text(message)
                .font(Theme.Stats.font13SemiBold)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            if let detail {
                Text(detail)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            }
            if canCancel, let progressText = scanningProgressText {
                Text(progressText)
                    .font(Theme.Stats.font10Regular.monospacedDigit())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                if let currentName = cleaner.scanProgress?.currentName {
                    Text(currentName)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
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

    /// 安全区合计：安全展示组的全部条目。
    private var safeSize: Int64 {
        DisplayGroup.allCases.filter(\.isSafe)
            .flatMap { items(for: $0) }
            .reduce(0) { $0 + $1.size }
    }

    private var resultsState: some View {
        VStack(spacing: 0) {
            resultsHero
                .padding(.horizontal, layout == .compact ? 12 : 16)
                .padding(.top, layout == .compact ? 12 : 16)
                .padding(.bottom, 10)
            Divider()
                .overlay(Theme.Stats.separator)
            if cleaner.items.isEmpty, cleaner.scanFailures.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 24)
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.Stats.statusNormal)
                    Text(strings.cleanerNothingFound)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
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
                    .overlay(Theme.Stats.separator)
                resultsFooter
            }
        }
    }

    /// 结果页主角：徽章 + 总量大数字 + 安全/可选比例条与图例。
    private var resultsHero: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                UtilityGlyphTile(symbol: "sparkles", tint: tint, size: 40, symbolSize: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.cleanerName)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    Text(String(format: strings.uninstallerFoundItemsFormat, cleaner.items.count))
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                }
                Spacer()
                Text(UtilityKit.byteString(cleaner.totalSize))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Button { cleaner.reset() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            if cleaner.totalSize > 0 {
                UtilityProportionBar(segments: [
                    .init(color: Theme.Stats.statusNormal, value: Double(safeSize)),
                    .init(color: Theme.Stats.ram, value: Double(cleaner.totalSize - safeSize)),
                ])
                HStack(spacing: 14) {
                    legendDot(color: Theme.Stats.statusNormal,
                              title: strings.cleanerSafeSection, size: safeSize)
                    legendDot(color: Theme.Stats.ram,
                              title: strings.cleanerOptionalSection, size: cleaner.totalSize - safeSize)
                    Spacer()
                }
            }
        }
        .padding(12)
        .utilityCardBackground()
    }

    private func legendDot(color: Color, title: String, size: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
            Text(UtilityKit.byteString(size))
                .font(Theme.Stats.font10Regular.monospacedDigit())
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
        }
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
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(Theme.Stats.ram)
            }
            if group == .loginItems {
                Text(strings.cleanerLoginItemsNote)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
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
                    .foregroundStyle(group.isSafe ? Theme.Stats.statusNormal : Theme.Stats.ram)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: group))
                        .font(Theme.Stats.font12Medium)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    Text(caption(for: group))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(UtilityKit.byteString(groupItems.reduce(0) { $0 + $1.size }))
                    .font(Theme.Stats.font11Regular.monospacedDigit())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
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
                Text(item.name)
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(prettyPath(item.url))
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(UtilityKit.byteString(item.size))
                .font(Theme.Stats.font10Regular.monospacedDigit())
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
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
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            Spacer()
            Button(strings.uninstallerCancel) { cleaner.reset() }
                .font(Theme.Stats.font12Medium)
            Button(String(format: strings.cleanerCleanSizeFormat,
                          UtilityKit.byteString(cleaner.selectedSize))) {
                cleaner.cleanSelected()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .font(Theme.Stats.font12Medium)
            .disabled(cleaner.selectedCount == 0)
        }
        .padding(layout == .compact ? 12 : 16)
    }

    // MARK: Done

    private func doneState(freed: Int64, failed: Int) -> some View {
        UtilityDoneView(
            strings: strings,
            freed: freed,
            failedCount: failed,
            note: strings.cleanerDoneNote,
            warning: strings.uninstallerSomeFailed,
            succeeded: cleaner.succeededItems.map { ($0.name, $0.url.path) },
            failures: cleaner.failedItems.map { ($0.item.name, $0.url.path, $0.message) },
            layout: layout
        ) {
            if !cleaner.failedItems.isEmpty {
                Button(strings.toolRetryFailures) { cleaner.retryFailures() }
                    .buttonStyle(.borderedProminent)
            }
            Button(strings.cleanerAgain) { cleaner.reset() }
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
}
