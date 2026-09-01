import SwiftUI

/// 卸载器的 App 选择器 sheet（搜索 + 列表），复用 InstalledApps 枚举。
struct UninstallerAppPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    let onCancel: () -> Void
    let onSelect: (URL) -> Void

    @State private var apps: [InstalledApps.InstalledApp] = []
    @State private var query = ""
    @State private var isLoading = false
    @FocusState private var searchFocused: Bool

    private var filteredApps: [InstalledApps.InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(trimmed)
                || (app.bundleID?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(strings.uninstallerPickerTitle)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Spacer()
                Button(strings.uninstallerCancel, action: onCancel)
                    .font(Theme.Stats.font12Medium)
            }

            TextField(strings.uninstallerPickerSearch, text: $query)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Stats.font12Medium)
                .focused($searchFocused)

            appList
        }
        .padding(18)
        .frame(width: 520, height: 560)
        // sheet 首个可聚焦控件（取消按钮）会带出系统蓝色键盘焦点环，按仓库惯例禁用。
        .omniNoFocusRing()
        .onAppear {
            loadAppsIfNeeded()
            focusSearchField()
        }
    }

    /// sheet 过场动画期间直接设焦点常被系统初始焦点覆盖，延后到动画落地后再聚焦。
    private func focusSearchField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchFocused = true
        }
    }

    @ViewBuilder
    private var appList: some View {
        let apps = filteredApps
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text(strings.uninstallerScanning)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                Text(strings.uninstallerPickerEmpty)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(apps) { app in
                        Button {
                            onSelect(app.url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                        .font(Theme.Stats.font12Medium)
                                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                                        .lineLimit(1)
                                    Text(app.bundleID ?? app.url.path)
                                        .font(Theme.Stats.font10Regular)
                                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func loadAppsIfNeeded() {
        guard apps.isEmpty, !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = InstalledApps.installedApplications()
            DispatchQueue.main.async {
                apps = loaded
                isLoading = false
            }
        }
    }
}
