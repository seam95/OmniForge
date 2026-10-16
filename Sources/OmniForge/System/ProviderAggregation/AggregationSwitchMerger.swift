import Foundation

/// 成员兼容开关合并 — 聚合投影的开关口径（对齐 cc-switch `controller.rs:256-327` `with_member_switches`）。
///
/// **为什么需要**：聚合投影先清掉全部拥有 env 键再写聚合键，否则直连模式残留的模型/窗口键
/// 会跟投影打架。副作用是每个成员自己配的兼容开关（`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、
/// `ENABLE_TOOL_SEARCH`…）被静默丢弃——需要某个开关保持关闭的成员，一进聚合就失去它。
///
/// **合并口径**：默认那家的既有值作底子；`others` = 非默认成员（名单序）；`others` 为空
/// （只有默认一家）时整个合并不执行。
/// - ANY 组（任一成员要关就关）：默认那家已"要关"→保持不动；否则取第一个"要关"的非默认成员的**原值**。
/// - ALL 组（只删不插）：非默认成员**全部显式开**才保留默认那家的既有值；任一未开/不可解析/缺键 → 删除。
/// - 值解析三态：`1/true/yes/on`→开、`0/false/no/off/空`→关、其余→不可解析。
///
/// 纯函数：不碰磁盘、不依赖 `ProviderAggregationManager`，调用方（投影写入侧）负责取名单与拼装 `others`。
enum AggregationSwitchMerger {
    /// 开关值三态（对齐 cc-switch `env_switch_on`）：显式开、显式关、不可解析。
    /// 不可解析既不算"要关"（ANY 组跳过该成员），也不算"显式开"（ALL 组按未开处理）。
    enum SwitchValue: Equatable {
        case on
        case off
        case unparseable
    }

    /// 合并后的开关值：键 → 最终写入的字符串（只含要写的键）。
    /// - Parameters:
    ///   - defaultProfile: 默认那家——合并底子，其 `extraEnv` 里六个键的既有值原样起步。
    ///   - others: 非默认成员（名单顺序，ANY 组取"第一个要关"即按此序）；为空 → 只保留底子。
    static func mergedValues(defaultProfile: ProviderProfile, others: [ProviderProfile]) -> [String: String] {
        // 底子 = 默认那家既有值（ALL 组的"保留"即它；ANY 组默认已要关则不被覆盖）。
        var merged: [String: String] = [:]
        for key in Self.mergedKeys where defaultProfile.extraEnv[key] != nil {
            merged[key] = defaultProfile.extraEnv[key]
        }

        // 只有默认一家 → 整个合并不执行。
        guard !others.isEmpty else { return merged }

        // ANY 组：默认那家已"要关"→不动；否则第一个"要关"的非默认成员贡献其原值。
        for entry in Self.anyGroup {
            guard defaultProfile.extraEnv[entry.key].map({ Self.switchValue($0) }) != entry.offValue else { continue }
            for member in others {
                guard let raw = member.extraEnv[entry.key], Self.switchValue(raw) == entry.offValue else { continue }
                merged[entry.key] = raw
                break
            }
        }

        // ALL 组：只删不插——非默认成员全部显式开才保留默认那家的值。
        for key in Self.allGroupKeys where merged[key] != nil {
            let everyMemberOn = others.allSatisfy { member in
                guard let raw = member.extraEnv[key] else { return false }   // 缺键 = 未开
                return Self.switchValue(raw) == .on
            }
            if !everyMemberOn {
                merged.removeValue(forKey: key)
            }
        }

        return merged
    }

    /// 开关字符串三态解析：小写 + 去首尾空白后查表（对齐 cc-switch `env_switch_on`）。
    static func switchValue(_ raw: String) -> SwitchValue {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "yes", "on": return .on
        case "0", "false", "no", "off", "": return .off
        default: return .unparseable
        }
    }

    // MARK: - private

    /// ANY 组条目：键 + 该键"要关"对应的值。
    private struct Entry {
        let key: String
        /// 该键"要关"的字面值：`DISABLE_*` 关=true，`AUTO_MODE_SERVER` 关=false。
        let offValue: SwitchValue
    }

    private static let anyGroup: [Entry] = [
        Entry(key: "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS", offValue: .on),
        Entry(key: "CLAUDE_CODE_DISABLE_ARTIFACT", offValue: .on),
        Entry(key: "CLAUDE_CODE_AUTO_MODE_SERVER", offValue: .off),
    ]

    /// ALL 组键：非默认成员全部显式开才保留。
    private static let allGroupKeys: [String] = [
        "ENABLE_TOOL_SEARCH",
        "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT",
        "CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING",
    ]

    /// 参与合并的全部键（ANY ∪ ALL）。
    private static var mergedKeys: [String] { anyGroup.map(\.key) + allGroupKeys }
}
