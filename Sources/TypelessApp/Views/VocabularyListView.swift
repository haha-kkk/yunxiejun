import SwiftUI

struct VocabularyListView: View {
    @EnvironmentObject private var vocabulary: VocabularyListController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("词典").font(.largeTitle).bold()
                    Spacer()
                    Button("新词") { vocabulary.beginAdding() }.disabled(!vocabulary.canEdit)
                        .accessibilityIdentifier("vocabulary-new")
                }
                Picker("词条来源", selection: $vocabulary.filter) {
                    ForEach(VocabularyListController.Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vocabulary-filter")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索词条", text: $vocabulary.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("vocabulary-search")
                    if !vocabulary.query.isEmpty {
                        Button { vocabulary.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清空搜索")
                    }
                    Button("刷新") { vocabulary.reload() }.disabled(vocabulary.isLoading || vocabulary.isSaving)
                }

                if vocabulary.isSaving { ProgressView("正在保存词条…").controlSize(.small) }
                if let notice = vocabulary.notice {
                    Text(notice).foregroundStyle(vocabulary.noticeIsError ? Color.red : Color.secondary)
                        .accessibilityIdentifier("vocabulary-notice")
                }
                if let undo = vocabulary.undo {
                    Button(undo.title) { vocabulary.undoLastEdit() }
                        .disabled(!vocabulary.canEdit)
                        .accessibilityIdentifier("vocabulary-undo")
                }

                switch vocabulary.state {
                case .idle, .loading:
                    HStack { ProgressView().controlSize(.small); Text("正在读取词典…") }
                        .accessibilityIdentifier("vocabulary-loading")
                case .failed(let message):
                    Text(message).foregroundStyle(.red).accessibilityIdentifier("vocabulary-error")
                    Button("重新读取") { vocabulary.reload() }
                case .loaded:
                    Text("显示 \(vocabulary.visibleTerms.count) / 共 \(vocabulary.terms.count) 个词条")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocabulary-count")
                    if vocabulary.visibleTerms.isEmpty {
                        Text(vocabulary.emptyMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityIdentifier("vocabulary-empty")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(vocabulary.visibleTerms) { term in
                                Button { vocabulary.beginEditing(term) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: term.source == .automatic ? "sparkles" : "leaf")
                                            .foregroundStyle(term.source == .automatic ? Color.mint : Color.secondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(term.text).font(.headline)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(term.source == .automatic ? "自动添加" : "手动添加")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(!vocabulary.canEdit)
                                .accessibilityLabel("\(term.text)，\(term.source == .automatic ? "自动添加" : "手动添加")，编辑词条")
                                .accessibilityIdentifier("vocabulary-term-\(term.id.uuidString)")
                            }
                        }
                    }
                }
                Text("词条保存在这台 Mac 上。点击词条可编辑或删除；支持撤销最近一次操作，退出应用后撤销记录清空。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { vocabulary.reload() }
        .onDisappear { vocabulary.cancelLoading(); vocabulary.dismissEditor() }
        .sheet(isPresented: $vocabulary.isEditorPresented) {
            VocabularyEditorView().environmentObject(vocabulary)
        }
    }
}
