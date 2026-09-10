import AppKit
import SwiftUI

/// 桌面宠物详情页（实用工具 compact 布局，平面分区）：
/// 启用开关 + 外观（内置 / 社区宠物选择、导入、移除）+ 尺寸三档 + 点击穿透提示。
@MainActor
struct DesktopPetDetailView: View {
    let strings: Strings
    /// 详情页仅在功能可用时可达，正常非 nil；防御式留空态。
    private let manager: DesktopPetManager?

    init(strings: Strings, manager: DesktopPetManager? = nil) {
        self.strings = strings
        self.manager = manager
            ?? FeatureRuntime.shared.manager(for: .desktopPet, as: DesktopPetManager.self)
    }

    var body: some View {
        if let manager {
            DesktopPetContent(strings: strings, manager: manager)
        } else {
            ContentUnavailableView(strings.featureHubNameDesktopPet, systemImage: "pawprint")
                .padding(.vertical, 24)
        }
    }
}

@MainActor
private struct DesktopPetContent: View {
    let strings: Strings
    @ObservedObject var manager: DesktopPetManager
    @Environment(\.colorScheme) private var colorScheme

    /// 导入结果提示（成功 / 失败）。
    @State private var importMessage: String?
    @State private var importFailed = false

    private var tint: Color { UtilityTool.desktopPet.tintColor }
    private var isEnabled: Bool {
        FeatureRuntime.shared.injectedDefaults.bool(forKey: UserDefaultsKeys.petEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            enableSection

            FlatHairline()

            appearanceSection

            FlatHairline()

            PetCommunitySection(strings: strings, manager: manager, browser: manager.community)

            FlatHairline()

            activitySection

            FlatHairline()

            sizeSection
        }
    }

    // MARK: - 好动程度

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlatSectionHeader(title: strings.desktopPetActivitySection, accent: tint)

            Picker(strings.desktopPetActivitySection, selection: Binding(
                get: { manager.activityPreset },
                set: { manager.setActivityPreset($0) }
            )) {
                Text(strings.desktopPetActivityQuiet).tag(PetBehaviorTuning.ActivityPreset.quiet)
                Text(strings.desktopPetActivityBalanced).tag(PetBehaviorTuning.ActivityPreset.balanced)
                Text(strings.desktopPetActivityLively).tag(PetBehaviorTuning.ActivityPreset.lively)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 启用开关

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(strings.desktopPetEnable, isOn: Binding(
                get: { isEnabled },
                set: { enabled in
                    // 写键后由 binding 统一建窗 / 拆窗，视图不直接持有窗口生命周期。
                    FeatureRuntime.shared.injectedDefaults.set(enabled, forKey: UserDefaultsKeys.petEnabled)
                    FeatureRuntime.shared.sync([.desktopPet])
                }
            ))
            .toggleStyle(.switch)
            .font(Theme.Stats.font12Medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 外观（宠物选择与导入）

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlatSectionHeader(title: strings.desktopPetAppearanceSection, accent: tint)

            let pets = manager.availablePets
            // 内置 + 社区宠物：整行可点，选中态用主题色勾选。
            VStack(spacing: 0) {
                ForEach(Array(pets.enumerated()), id: \.element.id) { index, pet in
                    if index > 0 {
                        Rectangle()
                            .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                    petRow(pet)
                }
            }

            HStack(spacing: 10) {
                Button(strings.desktopPetImportButton) { importPet() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if manager.isCustomPet {
                    Button(strings.desktopPetRemoveButton) { removeCurrentPet() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Text(strings.desktopPetImportHint)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let importMessage {
                Text(importMessage)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(importFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func petRow(_ pet: PetAssetStore.InstalledPet) -> some View {
        let selected = manager.selectedPetSlug == pet.slug
        return Button {
            manager.selectPet(slug: pet.slug)
        } label: {
            HStack(spacing: 8) {
                Text(pet.displayName)
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 尺寸档位

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlatSectionHeader(title: strings.desktopPetSizeSection, accent: tint)

            Picker(strings.desktopPetSizeSection, selection: Binding(
                get: { manager.size },
                set: { manager.setSize($0) }
            )) {
                ForEach(DesktopPetSize.allCases, id: \.self) { size in
                    Text(sizeName(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isEnabled)

            if manager.isClickThrough {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(strings.desktopPetClickThroughHint)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 档位展示名：Models 层不引用本地化，映射放在视图层。
    private func sizeName(_ size: DesktopPetSize) -> String {
        switch size {
        case .small: return strings.desktopPetSizeSmall
        case .medium: return strings.desktopPetSizeMedium
        case .large: return strings.desktopPetSizeLarge
        }
    }

    // MARK: - 导入 / 移除

    private func importPet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = strings.desktopPetImportButton
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pet = try manager.importPet(from: url)
            importFailed = false
            importMessage = String(
                format: strings.desktopPetImportSuccessFormat,
                pet.displayName
            )
        } catch {
            importFailed = true
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            importMessage = String(
                format: strings.desktopPetImportFailedFormat,
                detail
            )
        }
    }

    private func removeCurrentPet() {
        let slug = manager.selectedPetSlug
        do {
            try manager.removePet(slug: slug)
            importMessage = nil
        } catch {
            importFailed = true
            importMessage = String(
                format: strings.desktopPetImportFailedFormat,
                "\(error)"
            )
        }
    }
}
