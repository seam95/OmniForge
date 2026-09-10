import SwiftUI

/// 卸载器：拖入一个 app（或选择一个），审查它找到的遗留文件及其大小，
/// 然后把选中的移到废纸篓并查看释放的空间。功能本体托管于控制中心实用工具详情页。
///
/// 卸载器共享内容。宽版与紧凑版复用同一任务会话，仅调整可用空间。
struct UninstallerContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    let layout: UtilityContentLayout
    @ObservedObject var uninstaller: AppUninstaller
    @ObservedObject private var permissions = Permissions.shared
    @State private var dropTargeted = false
    @State private var showingAppPicker = false

    /// 品牌色：与实用工具列表行的卸载器徽章一致。
    private var tint: Color { UtilityTool.uninstaller.tintColor }

    init(
        strings: Strings,
        layout: UtilityContentLayout,
        uninstaller: AppUninstaller = .shared
    ) {
        self.strings = strings
        self.layout = layout
        self.uninstaller = uninstaller
    }

    var body: some View {
        content
            .frame(maxWidth: layout.contentWidth ?? .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch uninstaller.phase {
        case .empty: emptyState
        case .scanning: busyState(strings.uninstallerScanning)
        case .results: resultsState
        case .removing: busyState(strings.uninstallerRemoving)
        case let .done(freed, failed): doneState(freed: freed, failed: failed)
        }
    }

    // MARK: Empty / drop

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(dropTargeted ? tint : (colorScheme == .light ? Theme.Stats.separator : Color.secondary.opacity(0.35)))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(dropTargeted ? tint.opacity(0.07) : (colorScheme == .light ? Theme.Stats.cardBackground : Color.clear))
                )
                .frame(width: layout.dropTargetWidth, height: layout.dropTargetHeight)
                .overlay(
                    VStack(spacing: 10) {
                        UtilityGlyphTile(symbol: "trash", tint: dropTargeted ? tint : (MonitorOverviewPalette.auxiliary(colorScheme)),
                                         size: layout == .compact ? 44 : 52)
                        VStack(spacing: 3) {
                            Text(strings.uninstallerDropTitle)
                                .font(Theme.Stats.font13SemiBold)
                                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                            Text(strings.uninstallerDropSubtitle)
                                .font(Theme.Stats.font11Regular)
                                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                        }
                    }
                )
                .animation(.easeOut(duration: 0.15), value: dropTargeted)

            Button(strings.uninstallerChoose) { choose() }
                .controlSize(.regular)
                .font(Theme.Stats.font12Medium)

            Text(strings.uninstallerEmptyNote)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))

            if !permissions.fullDiskAccess { fullDiskAccessNote }
            Spacer()
        }
        .padding(layout.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: layout == .compact ? 420 : 480)
        .sheet(isPresented: $showingAppPicker) {
            UninstallerAppPickerView(strings: strings) {
                showingAppPicker = false
            } onSelect: { url in
                showingAppPicker = false
                uninstaller.select(appURL: url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) ?? urls.first else { return false }
            uninstaller.select(appURL: app)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// 完全磁盘访问提示：tint 横幅（共享 PanelTintBanner）。
    private var fullDiskAccessNote: some View {
        PanelTintBanner(
            icon: "info.circle",
            tint: Theme.Stats.cpu,
            title: strings.uninstallerFDANote,
            message: strings.uninstallerFDAHint
        ) {
            HStack(spacing: 8) {
                Button(strings.uninstallerFDAGrant) { permissions.requestFullDiskAccess() }
                // 与授权并列显示，因为访问仅在重新打开后生效。
                Button(strings.uninstallerFDARelaunch) {
                    (NSApp.delegate as? AppDelegate)?.relaunchApp()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: layout.dropTargetWidth)
    }

    // MARK: Busy

    private func busyState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(message)
                .font(Theme.Stats.font13SemiBold)
                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            if let target = uninstaller.target {
                HStack(spacing: 8) {
                    Image(nsImage: target.icon).resizable().frame(width: 18, height: 18)
                    Text(target.name)
                        .font(Theme.Stats.font12Medium)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    // inset 数据行语言：浅灰底圆角块
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Theme.Stats.cardInset)
                )
            }
            Spacer()
        }
    }

    // MARK: Results

    private var resultsState: some View {
        VStack(spacing: 0) {
            targetHero
            FlatHairline()
            List {
                ForEach(AppUninstaller.Category.allCases, id: \.self) { category in
                    let group = uninstaller.items.filter { $0.category == category }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { item in row(item) }
                        } header: {
                            categoryHeader(category, items: group)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .utilityResultsListHeight(layout)
            FlatHairline()
            footer
        }
    }

    /// 结果页主角：app 徽章 + 总量大数字 + 类别比例条（平铺白底）。
    private var targetHero: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let target = uninstaller.target {
                    Image(nsImage: target.icon).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                            .font(Theme.Stats.font13SemiBold)
                            .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                        Text(target.bundleID ?? target.url.path)
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UtilityKit.byteString(uninstaller.totalSize))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Text(String(format: strings.uninstallerFoundItemsFormat, uninstaller.items.count))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
                Button { uninstaller.reset() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
                .buttonStyle(.plain)
            }

            UtilityProportionBar(segments: categorySegments)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 按类别聚合的比例条分段；类别色与下方明细 section 的色点呼应。
    private var categorySegments: [UtilityProportionBar.Segment] {
        AppUninstaller.Category.allCases.compactMap { category in
            let size = uninstaller.items.filter { $0.category == category }.reduce(0) { $0 + $1.size }
            guard size > 0 else { return nil }
            return UtilityProportionBar.Segment(color: color(for: category), value: Double(size))
        }
    }

    private func color(for category: AppUninstaller.Category) -> Color {
        switch category {
        case .app: return tint
        case .support: return Theme.Stats.cpu
        case .caches: return Theme.Stats.ram
        case .preferences: return Theme.Stats.gpu
        case .containers: return .teal
        case .logs: return Theme.Stats.down
        case .state: return Theme.Stats.text3
        case .other: return Theme.Stats.text3.opacity(0.6)
        }
    }

    private func categoryHeader(_ category: AppUninstaller.Category, items group: [AppUninstaller.Leftover]) -> some View {
        FlatSectionHeader(title: label(for: category), accent: color(for: category)) {
            Text(UtilityKit.byteString(group.reduce(0) { $0 + $1.size }))
                .font(Theme.Stats.font10Regular.monospacedDigit())
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
        }
        .textCase(nil)
    }

    private func row(_ item: AppUninstaller.Leftover) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: includeBinding(item)).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1).truncationMode(.middle)
                Text(prettyPath(item.url))
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(UtilityKit.byteString(item.size))
                .font(Theme.Stats.font10Regular.monospacedDigit())
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .contextMenu {
            Button(strings.cleanerRevealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: strings.uninstallerSelectedFormat,
                            uninstaller.items.filter(\.include).count, uninstaller.items.count))
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                Text(UtilityKit.byteString(uninstaller.selectedSize))
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
            Spacer()
            Button(strings.uninstallerCancel) { uninstaller.reset() }
                .font(Theme.Stats.font12Medium)
            Button(strings.uninstallerRemove) { uninstaller.removeSelected() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Stats.up)
                .controlSize(.regular)
                .font(Theme.Stats.font12Medium)
                .disabled(!uninstaller.items.contains(where: \.include))
        }
        .padding(layout == .compact ? 12 : 16)
    }

    // MARK: Done

    private func doneState(freed: Int64, failed: Int) -> some View {
        UtilityDoneView(
            strings: strings,
            freed: freed,
            failedCount: failed,
            warning: strings.uninstallerSomeFailed,
            succeeded: uninstaller.succeededItems.map { ($0.name, $0.url.path) },
            failures: uninstaller.failedItems.map { ($0.item.name, $0.url.path, $0.message) },
            layout: layout
        ) {
            if !uninstaller.failedItems.isEmpty {
                Button(strings.toolRetryFailures) { uninstaller.retryFailures() }
                    .buttonStyle(.borderedProminent)
            }
            Button(strings.uninstallerAnother) { uninstaller.reset() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Helpers

    private func includeBinding(_ item: AppUninstaller.Leftover) -> Binding<Bool> {
        Binding(
            get: { uninstaller.items.first(where: { $0.id == item.id })?.include ?? false },
            set: { uninstaller.setInclude($0, for: item.id) }
        )
    }

    private func choose() {
        showingAppPicker = true
    }

    private func prettyPath(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func label(for category: AppUninstaller.Category) -> String {
        switch category {
        case .app: return strings.uninstallerCatApp
        case .support: return strings.uninstallerCatSupport
        case .caches: return strings.uninstallerCatCaches
        case .preferences: return strings.uninstallerCatPreferences
        case .containers: return strings.uninstallerCatContainers
        case .logs: return strings.uninstallerCatLogs
        case .state: return strings.uninstallerCatState
        case .other: return strings.uninstallerCatOther
        }
    }
}
