import SwiftUI

/// 卸载器的 App 选择器 sheet（搜索 + 列表），复用 InstalledApps 枚举。
struct UninstallerAppPickerView: View {
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
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(strings.uninstallerCancel, action: onCancel)
            }

            TextField(strings.uninstallerPickerSearch, text: $query)
                .textFieldStyle(.roundedBorder)

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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(strings.uninstallerPickerEmpty)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
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
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text(app.bundleID ?? app.url.path)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
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
