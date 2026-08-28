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

/// What's New 版本数据
struct WhatsNewRelease {
    let version: String
    let entries: [WhatsNewEntry]

    /// 当前版本的更新内容（硬编码，随版本更新时修改）
    static var currentRelease: WhatsNewRelease {
        WhatsNewRelease(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            entries: [
                WhatsNewEntry(type: .added, text: "新增 Onboarding 引导流程"),
                WhatsNewEntry(type: .changed, text: "优化权限管理，支持中断恢复"),
            ]
        )
    }
}

/// 版本更新展示窗口
struct WhatsNewView: View {
    let strings: Strings
    let onClose: () -> Void

    var body: some View {
        let release = WhatsNewRelease.currentRelease

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings.whatsNewTitle)
                        .font(.system(size: 22, weight: .bold))
                    Text("v\(release.version)")
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
                    ForEach(release.entries) { entry in
                        WhatsNewEntryRow(entry: entry)
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
