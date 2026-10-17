import SwiftUI

/// 聚合成员模型编辑区（Claude 侧 `stackModels`，SPEC §4 / P1-5）：
/// 每行「显示名称 / 实际请求模型 / 1M 复选 / 删除」，顶部「手动添加」追加空行，
/// 空态提示「未配置模型：把这家加入聚合后，模型选择器里不会多出它的模型」。
///
/// 行为对齐 cc-switch `ClaudeStackModelsField.tsx`（含 `normalizeClaudeStackModels`）。
/// 「从上游获取模型列表」（`FetchedModelPicker`）按 SPEC §4 另立专项，本期不做。
///
/// `normalize` / `fromMapping` 做成**静态纯函数**：界面测试暂缓实施（AGENTS.md——
/// SPM 目前不原生承载界面测试），这两个入口是「保存口径」与「未配置回显口径」
/// 唯一可直测的 seam，保存路径与回显路径都走它们。
struct ClaudeStackModelsField: View {
    @Binding var rows: [ClaudeStackModel]
    let strings: Strings

    @Environment(\.colorScheme) private var colorScheme

    init(rows: Binding<[ClaudeStackModel]>, strings: Strings) {
        self._rows = rows
        self.strings = strings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(strings.providerStackModelsSectionTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 0)

                Button {
                    rows.append(ClaudeStackModel(model: "", displayName: nil, oneM: false))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                .buttonStyle(.plain)
                .help(strings.providerStackModelsAdd)
            }

            if rows.isEmpty {
                Text(strings.providerStackModelsEmptyHint)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    row(at: index)
                }
            }
        }
    }

    // MARK: - 行

    private func row(at index: Int) -> some View {
        HStack(spacing: 8) {
            TextField(
                placeholder(at: index),
                text: displayNameBinding(at: index)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(inputBackground)
            .overlay(inputBorder)

            TextField(
                strings.providerStackModelsModelPlaceholder,
                text: modelBinding(at: index)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(inputBackground)
            .overlay(inputBorder)

            Toggle(isOn: oneMBinding(at: index)) {
                Text(strings.providerStackModelsOneM)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
            .toggleStyle(.checkbox)
            .frame(width: 52, alignment: .leading)

            Button {
                rows.remove(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
            .buttonStyle(.plain)
            .help(strings.providerStackModelsDelete)
        }
    }

    /// 显示名占位：行里已填模型名时用它兜底（对齐 cc-switch `modelBase || placeholder`），
    /// 免得空显示名让人以为这一行没内容。
    private func placeholder(at index: Int) -> String {
        let model = Self.stripOneMMarker(rows[index].model).model
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? strings.providerStackModelsDisplayNamePlaceholder : model
    }

    private func displayNameBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { rows[index].displayName ?? "" },
            // 原样存（含空串）：trim 交给 normalize，避免输入过程中空格被即时吃掉
            set: { newValue in updateRow(index) { $0.displayName = newValue } }
        )
    }

    private func modelBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { rows[index].model },
            set: { newValue in updateRow(index) { $0.model = newValue } }
        )
    }

    /// 1M 复选：模型名里写字面 `[1m]` 也视为已勾（发布侧同口径）；
    /// 勾选状态变化时把字面标记从模型名里剥掉——否则同一个 1M 会被记两处。
    private func oneMBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { rows[index].oneM || Self.hasOneMMarker(rows[index].model) },
            set: { enabled in
                let stripped = Self.stripOneMMarker(rows[index].model)
                updateRow(index) {
                    $0.model = stripped.model
                    $0.oneM = enabled
                }
            }
        )
    }

    /// 行级更新统一走「取值 → 改 → 写回」：不依赖 Binding 集合下标的写回细节。
    private func updateRow(_ index: Int, _ mutate: (inout ClaudeStackModel) -> Void) {
        var row = rows[index]
        mutate(&row)
        rows[index] = row
    }

    // MARK: - 视觉样式（与 ProfileEditorView 的映射行同一套常量）

    private var secondaryText: Color {
        Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
    }

    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.14)
                    : Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0),
                lineWidth: 1
            )
    }

    // MARK: - 纯函数（保存 / 回显口径）

    /// 存进 `profile.stackModels` 的样子：去空行、模型名字面 `[1M]`（大小写不敏感）转 `oneM`、
    /// 按剥标记后同名合并（任一勾 1M 即 1M、显示名取第一个非空）。
    ///
    /// 对齐 cc-switch `normalizeClaudeStackModels`（`ClaudeStackModelsField.tsx:38-63`）。
    /// 全空行 → `[]`：**空数组是「用户主动清空、什么都不发布」**，与 nil（未配置、按映射推导）
    /// 语义相反，保存侧不得把 `[]` 折算成 nil。
    static func normalize(_ rows: [ClaudeStackModel]) -> [ClaudeStackModel] {
        var result: [ClaudeStackModel] = []
        var indexByModel: [String: Int] = [:]

        for row in rows {
            let stripped = stripOneMMarker(row.model.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !stripped.model.isEmpty else { continue }
            let oneM = row.oneM || stripped.oneM
            let displayName = nonBlank(row.displayName)

            if let existing = indexByModel[stripped.model] {
                if oneM { result[existing].oneM = true }
                if result[existing].displayName == nil, let displayName {
                    result[existing].displayName = displayName
                }
                continue
            }

            indexByModel[stripped.model] = result.count
            result.append(ClaudeStackModel(model: stripped.model, displayName: displayName, oneM: oneM))
        }
        return result
    }

    /// 未配置（`stackModels == nil`）时的回显：`profile.aggregationModels`，
    /// 推导序即回显序（`ANTHROPIC_MODEL` → opus → sonnet → haiku → fable，见该属性文档）。
    ///
    /// 已配置（含空数组）→ 原样返回：`[]` 是用户主动清空，不得被推导值顶掉。
    /// 不回写 normalize：这里要显示用户存进去的原值（发布侧按字面标记识别 1M），
    /// 用户一保存才会走 normalize 收敛。
    static func fromMapping(profile: ProviderProfile) -> [ClaudeStackModel] {
        profile.aggregationModels
    }

    /// 第一行（= 这家被设为默认时的默认模型）写进 `ANTHROPIC_MODEL` 的样子：
    /// normalize 后取首行，1M 行补规范标记；列表为空 → nil（没有默认模型）。
    ///
    /// 对齐 cc-switch `claudeStackDefaultModel`（`ProviderForm.tsx:264-271`）——
    /// 表单的首行联动（`ProviderForm.tsx:685-691`）就拿它比对新旧值。
    static func defaultModel(_ rows: [ClaudeStackModel]) -> String? {
        guard let first = normalize(rows).first else { return nil }
        return first.oneM ? first.model + oneMMarker : first.model
    }

    /// 1M 字面标记（与 `AggregationModelID.oneMMarker` 同值）。Views 不依赖 System 层，
    /// 故按字面约定在此复刻——两侧改动必须同步。
    private static let oneMMarker = "[1M]"

    /// 模型名末尾是否带 1M 字面标记（大小写不敏感，仅看末尾——对齐 cc-switch
    /// `hasClaudeOneMMarker` 与 `AggregationModelID.stripOneMMarker`）。
    static func hasOneMMarker(_ model: String) -> Bool {
        trimEnd(model).lowercased().hasSuffix(oneMMarker.lowercased())
    }

    /// 按勾选态写 1M 字面标记（cc-switch `setClaudeOneMMarker` 同款；拼接形态与
    /// `defaultModel` 一致的无空格 `k3[1M]`，strip 两侧形态都认）：
    /// 基础名剥标记后 trim；空基础名 → 空串（值空了 1M 无从谈起，不让复选凭空留住标记）。
    /// 调用方：本视图行复选、直连表单映射行复选（模型映射值同以字面标记承载 1M）。
    static func setOneMMarker(_ model: String, _ enabled: Bool) -> String {
        let base = stripOneMMarker(model).model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return enabled ? base + oneMMarker : base
    }

    /// 剥掉末尾 1M 字面标记（大小写不敏感）——cc-switch `stripClaudeOneMMarker` 同款：
    /// 先去掉尾空白再判后缀，剥完再去一次尾空白（`k3 [1M]` → `k3`）。
    static func stripOneMMarker(_ model: String) -> (model: String, oneM: Bool) {
        let trimmedEnd = trimEnd(model)
        guard trimmedEnd.lowercased().hasSuffix(oneMMarker.lowercased()) else {
            return (model, false)
        }
        return (trimEnd(String(trimmedEnd.dropLast(oneMMarker.count))), true)
    }

    /// 去首尾空白；空串 → nil（与 `ProviderProfile` 的「空串 = 未配置」同口径）。
    private static func nonBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 去掉末尾空白（JS `trimEnd` 同义）。
    private static func trimEnd(_ text: String) -> String {
        String(text.reversed().drop { $0.isWhitespace }.reversed())
    }
}
