import Foundation

/// 将 TIS `kTISPropertyLocalizedName` 对齐到应用内语言。
/// 系统/进程语言与 `L10n` 不一致时，系统拼音等会显示英文名；此处按 id 与常见英文名映射修正。
enum InputSourceDisplayName {
    struct LocalizedPair: Equatable {
        let en: String
        let zhHans: String

        func name(for language: AppLanguage) -> String {
            switch language {
            case .en: return en
            case .zhHans: return zhHans
            }
        }
    }

    /// 常见系统键盘/输入法 id → 中英显示名。
    private static let idTable: [String: LocalizedPair] = [
        "com.apple.keylayout.ABC": .init(en: "ABC", zhHans: "ABC"),
        "com.apple.keylayout.US": .init(en: "U.S.", zhHans: "美国"),
        "com.apple.inputmethod.SCIM.ITABC": .init(en: "Pinyin - Simplified", zhHans: "简体拼音"),
        "com.apple.inputmethod.SCIM.Shuangpin": .init(en: "Shuangpin - Simplified", zhHans: "简体双拼"),
        "com.apple.inputmethod.SCIM.WBX": .init(en: "Wubi - Simplified", zhHans: "简体五笔"),
        "com.apple.inputmethod.SCIM.WBH": .init(en: "Stroke - Simplified", zhHans: "简体笔画"),
        "com.apple.inputmethod.TCIM.Pinyin": .init(en: "Pinyin - Traditional", zhHans: "繁体拼音"),
        "com.apple.inputmethod.TCIM.Zhuyin": .init(en: "Zhuyin - Traditional", zhHans: "繁体注音"),
        "com.apple.inputmethod.TCIM.Cangjie": .init(en: "Cangjie - Traditional", zhHans: "繁体仓颉"),
        "com.apple.inputmethod.TCIM.Sucheng": .init(en: "Sucheng - Traditional", zhHans: "繁体速成"),
        "com.apple.inputmethod.TCIM.Stroke": .init(en: "Stroke - Traditional", zhHans: "繁体笔画"),
        "com.apple.inputmethod.TYIM.Stroke": .init(en: "Stroke - Traditional", zhHans: "繁体笔画"),
        "com.apple.inputmethod.Kotoeri.RomajiTyping": .init(en: "Romaji", zhHans: "日语罗马字"),
        "com.apple.inputmethod.Kotoeri.Japanese": .init(en: "Hiragana", zhHans: "日语平假名"),
        "com.apple.inputmethod.Korean.2SetKorean": .init(en: "2-Set Korean", zhHans: "两套型韩文"),
    ]

    /// TIS 在英文系统下常见的显示名 → 目标语言。
    private static let englishNameTable: [String: LocalizedPair] = [
        "ABC": .init(en: "ABC", zhHans: "ABC"),
        "Pinyin - Simplified": .init(en: "Pinyin - Simplified", zhHans: "简体拼音"),
        "Shuangpin - Simplified": .init(en: "Shuangpin - Simplified", zhHans: "简体双拼"),
        "Wubi - Simplified": .init(en: "Wubi - Simplified", zhHans: "简体五笔"),
        "Stroke - Simplified": .init(en: "Stroke - Simplified", zhHans: "简体笔画"),
        "Pinyin - Traditional": .init(en: "Pinyin - Traditional", zhHans: "繁体拼音"),
        "Zhuyin - Traditional": .init(en: "Zhuyin - Traditional", zhHans: "繁体注音"),
        "Cangjie - Traditional": .init(en: "Cangjie - Traditional", zhHans: "繁体仓颉"),
        "Sucheng - Traditional": .init(en: "Sucheng - Traditional", zhHans: "繁体速成"),
        "Stroke - Traditional": .init(en: "Stroke - Traditional", zhHans: "繁体笔画"),
    ]

    /// 中文系统下常见显示名 → 目标语言（应用切到英文时用）。
    private static let chineseNameTable: [String: LocalizedPair] = [
        "简体拼音": .init(en: "Pinyin - Simplified", zhHans: "简体拼音"),
        "简体双拼": .init(en: "Shuangpin - Simplified", zhHans: "简体双拼"),
        "简体五笔": .init(en: "Wubi - Simplified", zhHans: "简体五笔"),
        "简体笔画": .init(en: "Stroke - Simplified", zhHans: "简体笔画"),
        "繁体拼音": .init(en: "Pinyin - Traditional", zhHans: "繁体拼音"),
        "繁体注音": .init(en: "Zhuyin - Traditional", zhHans: "繁体注音"),
        "繁体仓颉": .init(en: "Cangjie - Traditional", zhHans: "繁体仓颉"),
        "繁体速成": .init(en: "Sucheng - Traditional", zhHans: "繁体速成"),
        "繁体笔画": .init(en: "Stroke - Traditional", zhHans: "繁体笔画"),
    ]

    static func resolve(id: String, fallback: String, language: AppLanguage) -> String {
        if let pair = idTable[id] {
            return pair.name(for: language)
        }
        if let pair = pairMatchingIDSuffix(id) {
            return pair.name(for: language)
        }
        if let pair = englishNameTable[fallback] {
            return pair.name(for: language)
        }
        if let pair = chineseNameTable[fallback] {
            return pair.name(for: language)
        }
        return fallback
    }

    static func localized(_ source: InputSource, language: AppLanguage) -> InputSource {
        InputSource(
            id: source.id,
            name: resolve(id: source.id, fallback: source.name, language: language),
            isSelectable: source.isSelectable,
            isEnabled: source.isEnabled,
            icon: source.icon
        )
    }

    /// 兼容 InputModeID 前缀/后缀变体（如带语言后缀）。
    private static func pairMatchingIDSuffix(_ id: String) -> LocalizedPair? {
        // 精确表未命中时，按稳定后缀匹配常见 SCIM/TCIM 模式。
        let suffixes: [(String, LocalizedPair)] = [
            (".SCIM.ITABC", .init(en: "Pinyin - Simplified", zhHans: "简体拼音")),
            (".SCIM.Shuangpin", .init(en: "Shuangpin - Simplified", zhHans: "简体双拼")),
            (".SCIM.WBX", .init(en: "Wubi - Simplified", zhHans: "简体五笔")),
            (".TCIM.Pinyin", .init(en: "Pinyin - Traditional", zhHans: "繁体拼音")),
            (".TCIM.Zhuyin", .init(en: "Zhuyin - Traditional", zhHans: "繁体注音")),
            (".TCIM.Cangjie", .init(en: "Cangjie - Traditional", zhHans: "繁体仓颉")),
            (".TCIM.Sucheng", .init(en: "Sucheng - Traditional", zhHans: "繁体速成")),
        ]
        for (suffix, pair) in suffixes where id.hasSuffix(suffix) || id.contains(suffix) {
            return pair
        }
        return nil
    }
}
