import SwiftUI

/// 配置文件原文编辑器（进阶出口，SPEC 2.10）：查看并直接编辑 `settings.json` / `config.toml` 原文；
/// 保存前校验 JSON/TOML 合法性，非法拒绝保存；保存走与切换一致的「备份 + 原子写」。
struct ConfigFileEditorView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: strings.providerEditorTitleFormat, tool.displayName(in: strings)))
                .font(.headline)
            Text(strings.providerEditorHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
                .frame(minHeight: 260)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(strings.providerFormCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(strings.providerFormSave, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !text.isEmpty && manager.configFileEditor?.isValid(tool: tool, content: text) == true
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        text = (try? manager.configFileEditor?.read(tool: tool)) ?? ""
    }

    private func save() {
        do {
            try manager.configFileEditor?.save(tool: tool, content: text)
            dismiss()
        } catch ConfigFileEditorError.invalidContent {
            errorMessage = strings.providerEditorInvalidContent
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
