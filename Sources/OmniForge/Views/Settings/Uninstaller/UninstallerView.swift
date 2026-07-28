import SwiftUI

/// 卸载器，作为 Settings 页面嵌入：拖入一个 app（或选择一个），
/// 审查它找到的遗留文件及其大小，然后把选中的移到废纸篓并查看释放的空间。
struct UninstallerView: View {
    let strings: Strings

    var body: some View {
        UninstallerContentView(strings: strings, layout: .settings)
    }
}

/// 卸载器共享内容。宽版与紧凑版复用同一任务会话，仅调整可用空间。
struct UninstallerContentView: View {
    let strings: Strings
    let layout: UtilityContentLayout
    @ObservedObject var uninstaller: AppUninstaller
    @ObservedObject private var permissions = Permissions.shared
    @State private var dropTargeted = false
    @State private var showingAppPicker = false

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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )
                .frame(width: layout.dropTargetWidth, height: layout.dropTargetHeight)
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: "trash.square")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                        Text(strings.uninstallerDropTitle)
                            .font(.system(size: 16, weight: .semibold))
                        Text(strings.uninstallerDropSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                )
                .animation(.easeOut(duration: 0.15), value: dropTargeted)

            Button(strings.uninstallerChoose) { choose() }
                .controlSize(.large)

            Text(strings.uninstallerEmptyNote)
                .font(.caption)
                .foregroundStyle(.tertiary)

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

    private var fullDiskAccessNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(strings.uninstallerFDANote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(strings.uninstallerFDAHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(strings.uninstallerFDAGrant) { permissions.requestFullDiskAccess() }
                // 与授权并列显示，因为访问仅在重新打开后生效。
                Button(strings.uninstallerFDARelaunch) {
                    (NSApp.delegate as? AppDelegate)?.relaunchApp()
                }
            }
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: layout.dropTargetWidth)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Busy

    private func busyState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
            if let target = uninstaller.target {
                HStack(spacing: 8) {
                    Image(nsImage: target.icon).resizable().frame(width: 18, height: 18)
                    Text(target.name).font(.callout)
                }
            }
            Spacer()
        }
    }

    // MARK: Results

    private var resultsState: some View {
        VStack(spacing: 0) {
            targetHeader
            Divider()
            List {
                ForEach(AppUninstaller.Category.allCases, id: \.self) { category in
                    let group = uninstaller.items.filter { $0.category == category }
                    if !group.isEmpty {
                        Section(label(for: category)) {
                            ForEach(group) { item in row(item) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .utilityResultsListHeight(layout)
            Divider()
            footer
        }
    }

    private var targetHeader: some View {
        HStack(spacing: 12) {
            if let target = uninstaller.target {
                Image(nsImage: target.icon).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.system(size: 16, weight: .semibold))
                    Text(target.bundleID ?? target.url.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.byteString(uninstaller.totalSize))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(strings.uninstallerFoundTitle).font(.caption2).foregroundStyle(.secondary)
            }
            Button { uninstaller.reset() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(layout == .compact ? 12 : 16)
    }

    private func row(_ item: AppUninstaller.Leftover) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: includeBinding(item)).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text(prettyPath(item.url))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(Self.byteString(item.size))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: strings.uninstallerSelectedFormat,
                            uninstaller.items.filter(\.include).count, uninstaller.items.count))
                    .font(.system(size: 12, weight: .medium))
                Text(Self.byteString(uninstaller.selectedSize))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(strings.uninstallerCancel) { uninstaller.reset() }
            Button(strings.uninstallerRemove) { uninstaller.removeSelected() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!uninstaller.items.contains(where: \.include))
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
                if failed > 0 {
                    Text(strings.uninstallerSomeFailed)
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                executionDetails

                HStack(spacing: 8) {
                    if !uninstaller.failedItems.isEmpty {
                        Button(strings.toolRetryFailures) { uninstaller.retryFailures() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(strings.uninstallerAnother) { uninstaller.reset() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(layout.horizontalPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var executionDetails: some View {
        if !uninstaller.succeededItems.isEmpty || !uninstaller.failedItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !uninstaller.succeededItems.isEmpty {
                    resultSectionHeader(strings.toolSucceeded, count: uninstaller.succeededItems.count, color: .green)
                    ForEach(uninstaller.succeededItems) { item in
                        resultRow(name: item.name, path: item.url.path, message: nil)
                    }
                }
                if !uninstaller.failedItems.isEmpty {
                    resultSectionHeader(strings.toolFailed, count: uninstaller.failedItems.count, color: .orange)
                    ForEach(uninstaller.failedItems) { failure in
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

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
