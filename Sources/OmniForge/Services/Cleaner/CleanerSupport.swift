import Foundation

/// 垃圾清理的纯决策逻辑 —— 不依赖 AppKit 和文件系统，便于单元测试固定每条安全规则。
///
/// 清理器的承诺是：绝不触碰 owner 仍存在的任何文件。一个文件只有当其名称可映射到
/// bundle id、该 id 非 Apple、非本 app、且无任何已安装 app 持有它（含前缀家族匹配）时，
/// 才成为残留候选。其余清理对象（缓存、日志）都是 owner 可自行重建的内容。
enum CleanerSupport {
    /// 清理器能发现的内容类型，按展示顺序排列。新增 case 只能追加到末尾：rawValue 是稳定标识。
    enum Category: Int, CaseIterable, Identifiable {
        case leftovers, loginItems, caches, logs, developer, trash, deviceBackups

        var id: Int { rawValue }
    }

    /// 嵌入在其他厂商 app 里的跨产品基础设施（更新器、崩溃报告、分析）：
    /// 它们的目录属于承载它们的已安装 app，无法归因到某个已卸载 app，因此永不是垃圾 owner。
    static let sharedInfrastructurePrefixes = [
        "org.sparkle-project", "com.plausiblelabs", "com.crashlytics",
        "com.segment", "io.sentry", "com.amplitude", "com.rollbar",
        "com.google.keystone", "com.google.softwareupdate", "org.cups",
        "org.swift",
    ]

    /// 绝不能被当作垃圾 owner 的 bundle id，无论已安装 app 预言机怎么说：
    /// 操作系统自身域（任何包裹形式，含 team 前缀 group 名和 systemgroup）、本 app、共享基础设施。
    /// 本 app 的保护前缀同时覆盖新名 `app.omniforge` 与历史名 `app.inputlock`，
    /// 避免清理器误删老版本残留的用户数据（改名后老数据仍需保留供迁移）。
    static func isProtectedBundleID(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let wrapped = "." + lowered + "."
        if wrapped.contains(".com.apple.") || wrapped.contains(".app.omniforge.")
            || wrapped.contains(".app.inputlock.")
            || wrapped.contains(".developer.apple.") || wrapped.contains(".is.workflow.") {
            return true
        }
        if lowered == "com.apple" || lowered.hasPrefix("app.omniforge.") || lowered.hasPrefix("app.inputlock.") {
            return true
        }
        return sharedInfrastructurePrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Library 条目名是否形如反向 DNS bundle id（至少 3 个由纯标识符字符组成的点分隔段）。
    /// 其他形式（含纯厂商目录名）永不按名匹配 —— 太容易误伤活跃 app 数据。
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        for part in parts {
            guard !part.isEmpty else { return false }
            for scalar in part.unicodeScalars {
                let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                    || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
                guard ok else { return false }
            }
        }
        return true
    }

    /// 从 Library 条目名提取所属 bundle id：剥离已知包裹（group. 前缀）和载荷后缀
    /// （.plist、.savedState、.binarycookies）并校验形状。名称无法明确归属单一 bundle 时返回 nil。
    static func bundleIDCandidate(fromEntryName rawName: String) -> String? {
        // 名称中任何位置的 UUID（per-host 偏好、更新时间戳）使 owner 不可归因，此类条目永不是候选。
        guard !containsUUIDComponent(rawName) else { return nil }
        var name = rawName
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        for prefix in ["group.", "systemgroup."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        guard looksLikeBundleID(name) else { return nil }
        return name
    }

    /// 名称中是否包含带连字符的 UUID（8-4-4-4-12 十六进制组）。
    static func containsUUIDComponent(_ name: String) -> Bool {
        let lengths = [8, 4, 4, 4, 12]
        let scalars = Array(name.unicodeScalars)
        var index = 0
        while index < scalars.count {
            var cursor = index
            var matched = true
            for (group, length) in lengths.enumerated() {
                for _ in 0..<length {
                    guard cursor < scalars.count, isHexDigit(scalars[cursor]) else { matched = false; break }
                    cursor += 1
                }
                guard matched else { break }
                if group < lengths.count - 1 {
                    guard cursor < scalars.count, scalars[cursor] == "-" else { matched = false; break }
                    cursor += 1
                }
            }
            if matched { return true }
            index += 1
        }
        return false
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f") || (scalar >= "A" && scalar <= "F")
    }

    /// 第二段组件是代码托管站命名空间，互不相关的开发者共享该前缀；两段匹配在这里毫无意义。
    private static let hostingNamespaces: Set<String> = [
        "github", "gitlab", "bitbucket", "sourceforge", "googlecode",
    ]

    /// 候选是否与某个已安装 id 共享厂商命名空间（前两个点分隔段）。厂商以一个命名空间发布套件和
    /// 更新器，这些 sibling id 无法被精确家族匹配关联（已安装的 com.maker.editor 让 com.maker.updater
    /// 保持活跃），因此只要该厂商有任何东西已安装，整个命名空间都视为已被持有。
    static func sharesVendorNamespace(candidate: String, withInstalled installed: Set<String>) -> Bool {
        guard let namespacePrefix = vendorNamespace(of: candidate.lowercased()) else { return false }
        return installed.contains { vendorNamespace(of: $0) == namespacePrefix }
    }

    private static func vendorNamespace(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let vendor = String(parts[1])
        guard !hostingNamespaces.contains(vendor) else { return nil }
        return parts[0] + "." + parts[1]
    }

    /// 已安装 bundle id 是否持有此候选。归属关系是精确 id 或任一方向的点分隔前缀：
    /// com.maker.App 持有 com.maker.App.helper（内嵌 helper 不注册自己的 app），
    /// com.maker 持有 com.maker.App。
    static func isOwned(candidate: String, byInstalled installed: Set<String>) -> Bool {
        let lowered = candidate.lowercased()
        if installed.contains(lowered) { return true }
        for id in installed {
            if lowered.hasPrefix(id + ".") || id.hasPrefix(lowered + ".") { return true }
        }
        return false
    }

    /// launchd plist 指向的可执行文件，按检查顺序排列。所有引用可执行文件均已缺失的 plist
    /// 是孤儿：安装它的 app 已不存在。
    static func executablePaths(inLaunchPlist plist: [String: Any]) -> [String] {
        var paths: [String] = []
        if let program = plist["Program"] as? String, !program.isEmpty {
            paths.append(program)
        }
        if let arguments = plist["ProgramArguments"] as? [Any],
           let first = arguments.first as? String, !first.isEmpty {
            paths.append(first)
        }
        // BundleProgram 相对于 plist 所在 bundle；到达 launchd 目录时它携带一个绝对 sibling，
        // 裸相对路径无法解析，此处忽略。
        if let bundleProgram = plist["BundleProgram"] as? String, bundleProgram.hasPrefix("/") {
            paths.append(bundleProgram)
        }
        return paths
    }

    /// 孤儿 launchd plist 是否可被提供清理。Apple 自身 agent 是系统状态，未命名可执行文件的
    /// 无法判定，两者都不触碰。
    static func launchPlistIsRemovableOrphan(label: String?,
                                             executables: [String],
                                             executableExists: (String) -> Bool) -> Bool {
        if let label, isProtectedBundleID(label) { return false }
        guard !executables.isEmpty else { return false }
        return !executables.contains(where: executableExists)
    }
}
