import SwiftUI

/// 连通性测试成功后的模型选择弹窗（Codex 回填，对齐 cc-switch `FetchedModelPicker`）：
/// - 勾选状态即「在不在表单模型列表里」：打开时已配置的模型都勾着，取消勾选即移除；
/// - 已配置但供应商未返回的模型单独置顶分组（取消勾选即从表单删掉它）；
/// - 「应用」才把增删交给调用方；取消什么都不改。
struct ProviderModelPickerSheet: View {
    let strings: Strings
    /// 连通性测试拉到的模型列表（供应商顺序）。
    let fetchedModels: [String]
    /// 表单当前已配置的模型行（已过滤空白，原始顺序）。
    let configuredModels: [String]
    /// 应用：传回勾选的模型（配置未返回组原顺序在前、供应商顺序在后）。
    let onApply: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selected: Set<String> = []
    @State private var searchText = ""

    /// 已配置、供应商未返回（置顶单列——这些行不在供应商列表里，只能在这里勾选）。
    /// 去重保序：ForEach 以模型名为 id，重复 id 会让 SwiftUI 渲染错乱。
    private var configuredNotReturned: [String] {
        Self.deduped(configuredModels.filter { !fetchedModels.contains($0) })
    }

    private var filteredConfigured: [String] { filtered(configuredNotReturned) }
    private var filteredAvailable: [String] { filtered(Self.deduped(fetchedModels)) }

    private static func deduped(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(strings.providerModelPickerTitle)
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 16)
                .padding(.bottom, 10)

            TextField(strings.providerModelPickerSearchPlaceholder, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if !filteredConfigured.isEmpty {
                        sectionHeader(strings.providerModelPickerConfiguredSection)
                        ForEach(filteredConfigured, id: \.self) { model in
                            modelRow(model)
                        }
                    }
                    if !filteredAvailable.isEmpty {
                        sectionHeader(strings.providerModelPickerAvailableSection)
                        ForEach(filteredAvailable, id: \.self) { model in
                            modelRow(model)
                        }
                    }
                    if filteredConfigured.isEmpty && filteredAvailable.isEmpty {
                        Text(strings.providerModelPickerNoMatches)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            HStack {
                Button(strings.providerFormCancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(strings.providerModelPickerApply) {
                    // 顺序：配置未返回组（保原相对顺序）在前，供应商顺序在后——
                    // 已有行的位置尽量不动，新勾的按供应商列表顺序追加。
                    let ordered = configuredNotReturned.filter { selected.contains($0) }
                        + fetchedModels.filter { selected.contains($0) }
                    onApply(ordered)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 480)
        .onAppear {
            selected = Set(configuredModels)
        }
    }

    // MARK: - private

    private func filtered(_ models: [String]) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter { $0.lowercased().contains(query) }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func modelRow(_ model: String) -> some View {
        let isChecked = selected.contains(model)
        return Button {
            if isChecked {
                selected.remove(model)
            } else {
                selected.insert(model)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                Text(model)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
