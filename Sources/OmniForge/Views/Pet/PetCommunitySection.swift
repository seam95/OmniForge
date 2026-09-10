import SwiftUI

/// 详情页「社区宠物」分区：浏览 petdex 清单、搜索、下载。
/// 内联展开（不弹 sheet），避免控制中心面板的弹窗焦点问题。
@MainActor
struct PetCommunitySection: View {
    let strings: Strings
    @ObservedObject var manager: DesktopPetManager
    @ObservedObject var browser: PetCommunityBrowser
    @Environment(\.colorScheme) private var colorScheme

    /// 是否展开社区列表。
    @State private var isExpanded = false
    @State private var keyword = ""

    private var tint: Color { UtilityTool.desktopPet.tintColor }
    /// 单次展示上限，避免长列表拖慢渲染。
    private let pageSize = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FlatSectionHeader(title: strings.desktopPetCommunitySection, accent: tint)
                Spacer(minLength: 8)
                Button(isExpanded ? strings.desktopPetCollapse : strings.desktopPetBrowseButton) {
                    isExpanded.toggle()
                    if isExpanded, case .idle = browser.state {
                        Task { await browser.load() }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(Theme.Stats.font11Regular)
            }

            if isExpanded {
                searchField

                switch browser.state {
                case .idle, .loading:
                    statusRow(strings.desktopPetCommunityLoading)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(.secondary)
                        Button(strings.desktopPetRetryButton) {
                            Task { await browser.load(forceRefresh: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .loaded:
                    resultList
                }

                Text(strings.desktopPetCommunityDisclaimer)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        TextField(strings.desktopPetSearchPlaceholder, text: $keyword)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(Theme.Stats.font12Medium)
    }

    @ViewBuilder
    private var resultList: some View {
        let results = browser.search(keyword, limit: pageSize)
        if results.isEmpty {
            statusRow(strings.desktopPetCommunityEmpty)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, pet in
                    if index > 0 {
                        Rectangle()
                            .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                    resultRow(pet)
                }
            }
        }
    }

    private func resultRow(_ pet: PetdexPet) -> some View {
        let installed = manager.installedPets.contains { $0.slug == pet.slug }
            || manager.selectedPetSlug == pet.slug
        let downloading = browser.downloadingSlugs.contains(pet.slug)
        let error = browser.downloadErrors[pet.slug]

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pet.displayName)
                        .font(Theme.Stats.font12Medium)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                        .lineLimit(1)
                    if !pet.submittedBy.isEmpty {
                        Text(pet.submittedBy)
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailingControl(pet: pet, installed: installed, downloading: downloading)
            }
            if let error {
                Text(error)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailingControl(pet: PetdexPet, installed: Bool, downloading: Bool) -> some View {
        if downloading {
            Text(strings.desktopPetDownloading)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(.secondary)
        } else if installed {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(strings.desktopPetDownloadedBadge)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(strings.desktopPetDownloadButton) {
                Task { await manager.downloadCommunityPet(pet) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func statusRow(_ message: String) -> some View {
        Text(message)
            .font(Theme.Stats.font11Regular)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}
