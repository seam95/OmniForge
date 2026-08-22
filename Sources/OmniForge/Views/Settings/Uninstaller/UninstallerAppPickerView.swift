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

            appList
        }
        .padding(18)
        .frame(width: 520, height: 560)
        .onAppear { loadAppsIfNeeded() }
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
