import AppKit
import SwiftUI

/// 访达右键增强设置面板
struct RightClickSettingsView: View {
    @ObservedObject var state: AppState
    private let config: RightClickConfiguration

    @State private var newExtensionText: String = ""
    @State private var isSubmenuCollapsed: Bool = true
    @State private var promotedKeys: Set<String> = []
    @State private var fileExtensions: [String] = []
    @State private var favoriteDirectories: [RightClickDirectoryItem] = []
    @State private var extensionStatus: Bool = false

    private var s: Strings { state.l10n.s }

    init(state: AppState, configuration: RightClickConfiguration = .shared) {
        self.state = state
        self.config = configuration
    }

    var body: some View {
        Form {
            extensionStatusSection
            menuPresentationSection
            fileExtensionsSection
            favoriteDirectoriesSection
        }
        .settingsPageStyle()
        .onAppear {
            loadConfig()
            checkExtensionStatus()
        }
    }

    // MARK: - 1. 扩展状态指示

    private var extensionStatusSection: some View {
        Section(s.rightClickExtensionStatusSection) {
            HStack(spacing: 12) {
                Image(systemName: extensionStatus ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(extensionStatus ? .green : .orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(extensionStatus ? s.rightClickExtensionStatusEnabled : s.rightClickExtensionStatusDisabled)
                        .font(.body)
                }

                Spacer()

                Button(s.rightClickExtensionOpenSettingsButton) {
                    openExtensionSystemSettings()
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 2. 菜单结构与展示

    private var menuPresentationSection: some View {
        Section(s.rightClickMenuHierarchySection) {
            Toggle(s.rightClickSubmenuCollapsedToggle, isOn: $isSubmenuCollapsed)
                .onChange(of: isSubmenuCollapsed) { _, newValue in
                    config.isSubmenuCollapsed = newValue
                }

            Text(s.rightClickSubmenuCollapsedHint)
                .font(.footnote)
                .foregroundColor(.secondary)

            if isSubmenuCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.rightClickPromotedItemsSection)
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    Toggle(s.rightClickPromoteNewFile, isOn: bindingForPromotedKey("newFile"))
                    Toggle(s.rightClickPromoteTerminal, isOn: bindingForPromotedKey("openTerminal"))
                    Toggle(s.rightClickPromoteEditor, isOn: bindingForPromotedKey("openEditor"))
                    Toggle(s.rightClickPromoteCopyPath, isOn: bindingForPromotedKey("copyPath"))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 3. 新建文件扩展名

    private var fileExtensionsSection: some View {
        Section(s.rightClickFileExtensionsSection) {
            Text(s.rightClickFileExtensionsHint)
                .font(.footnote)
                .foregroundColor(.secondary)

            // 扩展名标签流
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(fileExtensions, id: \.self) { ext in
                        HStack(spacing: 4) {
                            Text(".\(ext)")
                                .font(.system(.body, design: .monospaced))
                            Button(action: { removeExtension(ext) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            // 新增扩展名输入框
            HStack(spacing: 8) {
                TextField(s.rightClickAddExtensionPlaceholder, text: $newExtensionText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Button(s.rightClickAddExtensionButton) {
                    addExtension()
                }
                .disabled(newExtensionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button(s.rightClickResetExtensionsButton) {
                    resetExtensions()
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - 4. 常用目标目录

    private var favoriteDirectoriesSection: some View {
        Section(s.rightClickFavoriteDirectoriesSection) {
            Text(s.rightClickFavoriteDirectoriesHint)
                .font(.footnote)
                .foregroundColor(.secondary)

            ForEach(favoriteDirectories) { item in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body)
                        Text(item.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if item.isCustom {
                        Button(action: { removeDirectory(item.id) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Button(s.rightClickAddDirectoryButton) {
                pickDirectory()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 业务交互动作

    private func loadConfig() {
        isSubmenuCollapsed = config.isSubmenuCollapsed
        promotedKeys = config.promotedActionKeys
        fileExtensions = config.fileExtensions
        favoriteDirectories = config.favoriteDirectories
    }

    private func bindingForPromotedKey(_ key: String) -> Binding<Bool> {
        Binding(
            get: { promotedKeys.contains(key) },
            set: { isPromoted in
                config.setActionPromoted(key, isPromoted: isPromoted)
                promotedKeys = config.promotedActionKeys
            }
        )
    }

    private func addExtension() {
        let trimmed = newExtensionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.addFileExtension(trimmed)
        fileExtensions = config.fileExtensions
        newExtensionText = ""
    }

    private func removeExtension(_ ext: String) {
        config.removeFileExtension(ext)
        fileExtensions = config.fileExtensions
    }

    private func resetExtensions() {
        config.resetFileExtensions()
        fileExtensions = config.fileExtensions
    }

    private func removeDirectory(_ id: UUID) {
        config.removeFavoriteDirectory(id: id)
        favoriteDirectories = config.favoriteDirectories
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"

        if panel.runModal() == .OK, let url = panel.url {
            let name = url.lastPathComponent
            config.addFavoriteDirectory(name: name, path: url.path)
            favoriteDirectories = config.favoriteDirectories
        }
    }

    private func openExtensionSystemSettings() {
        // macOS 13+ 登录项与扩展设置
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private func checkExtensionStatus() {
        // 尝试通过 pluginkit 检测插件启用状态
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.FinderSync", "-i", "app.omniforge.FinderSync"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), output.contains("app.omniforge.FinderSync") {
            extensionStatus = true
        } else {
            // 若应用未安装至 /Applications，pluginkit 查不到，默认显示提示
            extensionStatus = false
        }
    }
}
