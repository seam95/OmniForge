import AppKit
import SwiftUI

struct QuickPhraseEditorView: View {
    let phrase: QuickPhraseEntry?
    let allGroups: [String]
    /// 保存回调返回是否成功（审查 R19）：false = 存储失败，调用方保持 sheet
    /// 打开、草稿原样保留供重试；错误文案经 errorMessage 展示。
    let onSave: (String, String?) -> Bool
    let onCancel: () -> Void

    @State private var content: String
    @State private var group: String = ""
    @State private var customGroup: String = ""
    @State private var useCustomGroup: Bool = false
    @State private var saveError: String?

    init(phrase: QuickPhraseEntry?, allGroups: [String], onSave: @escaping (String, String?) -> Bool, onCancel: @escaping () -> Void) {
        self.phrase = phrase
        self.allGroups = allGroups
        self.onSave = onSave
        self.onCancel = onCancel
        _content = State(initialValue: phrase?.content ?? "")
        _group = State(initialValue: phrase?.group ?? "")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(phrase == nil ? "添加快捷用语" : "编辑快捷用语")
                .font(.system(size: 16, weight: .semibold))

            TextEditor(text: $content)
                .font(.system(size: 13))
                .frame(minHeight: 120, maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            HStack {
                Text("分组:")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Picker("", selection: $useCustomGroup) {
                    Text("选择分组").tag(false)
                    Text("自定义").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                if !useCustomGroup {
                    Picker("", selection: $group) {
                        Text("无").tag("")
                        ForEach(allGroups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                    .frame(width: 120)
                } else {
                    TextField("输入分组名", text: $customGroup)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消")
                        .frame(width: 60)
                }
                .buttonStyle(.plain)

                Button(action: save) {
                    Text("保存")
                        .frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let saveError {
                // 存储失败：草稿保留在编辑器内，修正错误或直接再点保存即重试。
                Text("保存失败：\(saveError)（内容已保留，可重试）")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        let finalGroup: String?
        if useCustomGroup {
            finalGroup = customGroup.isEmpty ? nil : customGroup
        } else {
            finalGroup = group.isEmpty ? nil : group
        }

        if !onSave(trimmedContent, finalGroup) {
            saveError = "存储不可用"
            return
        }
    }
}

struct QuickPhraseEditorView_Previews: PreviewProvider {
    static var previews: some View {
        QuickPhraseEditorView(
            phrase: nil,
            allGroups: ["工作", "生活"],
            onSave: { _, _ in true },
            onCancel: {}
        )
    }
}
