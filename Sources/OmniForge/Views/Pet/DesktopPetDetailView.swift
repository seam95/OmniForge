import SwiftUI

/// 桌面宠物详情页（实用工具 compact 布局，平面分区）：
/// 启用开关 + 尺寸三档 + 点击穿透提示。
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

    private var tint: Color { UtilityTool.desktopPet.tintColor }

    var body: some View {
        VStack(spacing: 0) {
            enableSection

            FlatHairline()

            sizeSection
        }
    }

    // MARK: - 启用开关

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(strings.desktopPetEnable, isOn: Binding(
                get: { FeatureRuntime.shared.injectedDefaults.bool(forKey: UserDefaultsKeys.petEnabled) },
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
            .disabled(!FeatureRuntime.shared.injectedDefaults.bool(forKey: UserDefaultsKeys.petEnabled))

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
}
