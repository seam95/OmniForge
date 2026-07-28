import AppKit
import SwiftUI

struct QuickPhraseEditorView: View {
    let phrase: QuickPhraseEntry?
    let allGroups: [String]
    let onSave: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var content: String
    @State private var group: String = ""
    @State private var customGroup: String = ""
    @State private var useCustomGroup: Bool = false

    init(phrase: QuickPhraseEntry?, allGroups: [String], onSave: @escaping (String, String?) -> Void, onCancel: @escaping () -> Void) {
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

        onSave(trimmedContent, finalGroup)
    }
}

struct QuickPhraseEditorView_Previews: PreviewProvider {
    static var previews: some View {
        QuickPhraseEditorView(
            phrase: nil,
            allGroups: ["工作", "生活"],
            onSave: { _, _ in },
            onCancel: {}
        )
    }
}
