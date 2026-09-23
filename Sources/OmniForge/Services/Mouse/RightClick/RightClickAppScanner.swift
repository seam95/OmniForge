import AppKit
import Foundation

public struct DiscoveredApp: Identifiable, Equatable, Hashable {
    public enum AppCategory: String, Codable {
        case terminal
        case editor
    }

    public var id: String { bundleId }
    public var name: String
    public var bundleId: String
    public var category: AppCategory
    public var appURL: URL?

    public init(name: String, bundleId: String, category: AppCategory, appURL: URL? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.category = category
        self.appURL = appURL
    }
}

/// 本机终端与代码编辑器扫描器
public final class RightClickAppScanner {
    public static let shared = RightClickAppScanner()

    public struct KnownAppDefinition {
        public let name: String
        public let bundleId: String
        public let category: DiscoveredApp.AppCategory

        public init(name: String, bundleId: String, category: DiscoveredApp.AppCategory) {
            self.name = name
            self.bundleId = bundleId
            self.category = category
        }
    }

    public static let knownTerminals: [KnownAppDefinition] = [
        .init(name: "Terminal", bundleId: "com.apple.Terminal", category: .terminal),
        .init(name: "iTerm2", bundleId: "com.googlecode.iterm2", category: .terminal),
        .init(name: "Warp", bundleId: "dev.warp", category: .terminal),
        .init(name: "Ghostty", bundleId: "com.mitchellh.ghostty", category: .terminal),
        .init(name: "Alacritty", bundleId: "io.alacritty", category: .terminal),
        .init(name: "kitty", bundleId: "net.kovidgoyal.kitty", category: .terminal),
        .init(name: "WezTerm", bundleId: "com.github.wez.wezterm", category: .terminal),
    ]

    public static let knownEditors: [KnownAppDefinition] = [
        .init(name: "VS Code", bundleId: "com.microsoft.VSCode", category: .editor),
        .init(name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92", category: .editor),
        .init(name: "Xcode", bundleId: "com.apple.dt.Xcode", category: .editor),
        .init(name: "Zed", bundleId: "dev.zed.Zed", category: .editor),
        .init(name: "Sublime Text", bundleId: "com.sublimetext.4", category: .editor),
        .init(name: "Sublime Text 3", bundleId: "com.sublimetext.3", category: .editor),
        .init(name: "Typora", bundleId: "abnerworks.Typora", category: .editor),
        .init(name: "IntelliJ IDEA", bundleId: "com.jetbrains.intellij", category: .editor),
        .init(name: "PyCharm", bundleId: "com.jetbrains.pycharm", category: .editor),
        .init(name: "WebStorm", bundleId: "com.jetbrains.webstorm", category: .editor),
    ]

    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    /// 扫描本机所有已安装的已知终端
    public func scanInstalledTerminals() -> [DiscoveredApp] {
        scanApps(from: Self.knownTerminals)
    }

    /// 扫描本机所有已安装的已知代码编辑器
    public func scanInstalledEditors() -> [DiscoveredApp] {
        scanApps(from: Self.knownEditors)
    }

    private func scanApps(from definitions: [KnownAppDefinition]) -> [DiscoveredApp] {
        var results: [DiscoveredApp] = []
        for def in definitions {
            if let url = workspace.urlForApplication(withBundleIdentifier: def.bundleId) {
                let displayName = FileManager.default.displayName(atPath: url.path)
                let name = displayName.isEmpty ? def.name : displayName.replacingOccurrences(of: ".app", with: "")
                results.append(DiscoveredApp(name: name, bundleId: def.bundleId, category: def.category, appURL: url))
            }
        }
        return results
    }
}
