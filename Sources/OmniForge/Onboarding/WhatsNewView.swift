import SwiftUI

/// What's New 条目类型
struct WhatsNewEntry: Identifiable {
    enum EntryType: Equatable {
        case added
        case fixed
        case changed

        var iconName: String {
            switch self {
            case .added: return "plus.circle.fill"
            case .fixed: return "checkmark.circle.fill"
            case .changed: return "slider.horizontal.3"
            }
        }

        var color: Color {
            switch self {
            case .added: return .green
            case .fixed: return .blue
            case .changed: return .orange
            }
        }
    }

    let id = UUID()
    let type: EntryType
    let text: String
}

/// What's New 版本数据；条目内容维护在 WhatsNewReleaseCatalog
struct WhatsNewRelease: Identifiable {
    let version: String
    let entries: [WhatsNewEntry]

    var id: String { version }
}

/// 版本更新展示窗口 — 展示自 lastSeenVersion 以来各版本的更新，多版本时按版本分组
struct WhatsNewView: View {
    let strings: Strings
    let lastSeenVersion: String?
    let onClose: () -> Void

    var body: some View {
        // 新版本在前；为空时 Catalog 已保证回退到最新一组
        let releases = WhatsNewReleaseCatalog.releases(after: lastSeenVersion)

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings.whatsNewTitle)
                        .font(.system(size: 22, weight: .bold))
                    Text("v\(releases.first?.version ?? "")")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(releases) { release in
                        // 单版本时顶部副标题已带版本号，仅多版本时再加组内小节标题
                        if releases.count > 1 {
                            Text("v\(release.version)")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                        ForEach(release.entries) { entry in
                            WhatsNewEntryRow(entry: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }

            Divider()

            HStack {
                Spacer()
                Button(strings.whatsNewClose, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .omniNoFocusRing()
    }
}

/// 单条更新条目
private struct WhatsNewEntryRow: View {
    let entry: WhatsNewEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.type.iconName)
                .font(.system(size: 14))
                .foregroundStyle(entry.type.color)
                .frame(width: 20)

            Text(entry.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
