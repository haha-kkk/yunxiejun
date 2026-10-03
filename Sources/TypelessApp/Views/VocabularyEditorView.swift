import SwiftUI

struct VocabularyEditorView: View {
    @EnvironmentObject private var vocabulary: VocabularyListController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(vocabulary.editingTerm == nil ? "添加新词" : "编辑词条").font(.title2).bold()
            TextField("例如 Claude", text: $vocabulary.draftText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(vocabulary.isSaving)
                .accessibilityLabel("词条名称")
                .accessibilityIdentifier("vocabulary-editor-text")
            Text(vocabulary.editingTerm?.source == .automatic ? "来源：自动添加（编辑后保留来源）" : "来源：手动添加")
                .font(.callout).foregroundStyle(.secondary)
            if let error = vocabulary.editError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vocabulary-editor-error")
            }
            if vocabulary.isSaving { ProgressView("正在保存…").controlSize(.small) }
            HStack {
                if vocabulary.editingTerm != nil {
                    Button("删除词条", role: .destructive) { vocabulary.deleteEditingTerm() }
                        .disabled(vocabulary.isSaving)
                }
                Spacer()
                Button("取消") { vocabulary.dismissEditor() }
                    .keyboardShortcut(.cancelAction).disabled(vocabulary.isSaving)
                Button("保存") { vocabulary.saveEditor() }
                    .keyboardShortcut(.defaultAction).disabled(!vocabulary.canSave)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(vocabulary.isSaving)
        .onAppear { focused = true }
        .onDisappear { vocabulary.dismissEditor() }
    }
}
