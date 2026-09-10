import AppKit
import SwiftUI

/// 详情页「社区宠物」分区：跳转 petdex 网站浏览挑选，回 App 按名字安装。
/// 列表样式预览不做（缩略图链路复杂），浏览体验交给样式丰富的官方网站。
@MainActor
struct PetCommunitySection: View {
    let strings: Strings
    @ObservedObject var manager: DesktopPetManager
    @ObservedObject var browser: PetCommunityBrowser

    /// 待安装的宠物名字（从网站复制）。
    @State private var petName = ""
    /// 安装进行中。
    @State private var isInstalling = false
    /// 安装结果提示（成功 / 失败原因）。
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var tint: Color { UtilityTool.desktopPet.tintColor }
    /// petdex 中文站（与 App 语言无关，统一中文站）。
    private static let siteURL = URL(string: "https://petdex.dev/zh")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FlatSectionHeader(title: strings.desktopPetCommunitySection, accent: tint)
                Spacer(minLength: 8)
            }

            Button {
                NSWorkspace.shared.open(Self.siteURL)
            } label: {
                Label(strings.desktopPetBrowseButton, systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Text(strings.desktopPetInstallByNameHint)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(strings.desktopPetInstallNamePlaceholder, text: $petName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(Theme.Stats.font12Medium)
                    .onSubmit { install() }

                Button(strings.desktopPetInstallButton) { install() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(petName.trimmingCharacters(in: .whitespaces).isEmpty || isInstalling)
            }

            if isInstalling {
                Text(strings.desktopPetDownloading)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(.secondary)
            } else if let resultMessage {
                Text(resultMessage)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(resultIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(strings.desktopPetCommunityDisclaimer)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func install() {
        let name = petName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isInstalling else { return }
        isInstalling = true
        resultMessage = nil
        Task { @MainActor in
            let result = await manager.installCommunityPet(byName: name)
            isInstalling = false
            switch result {
            case .success(let pet):
                resultIsError = false
                resultMessage = String(
                    format: strings.desktopPetImportSuccessFormat,
                    pet.displayName
                )
                petName = ""
            case .failure(let error):
                resultIsError = true
                resultMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
