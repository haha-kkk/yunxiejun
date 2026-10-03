import Combine
import Foundation

protocol VocabularyListing: Sendable {
    func list() async throws -> [VocabularyTerm]
}

protocol VocabularyEditing: VocabularyListing {
    func edit(_ edit: VocabularyEdit) async throws -> VocabularyEditResult
}

extension VocabularyStore: VocabularyEditing {}

/// 在非主 actor 上首次开库；页面关闭时保留连接，下次打开只重新读取。
actor LocalVocabularyReader: VocabularyEditing, CorrectionLearning, TranscriptArchiving {
    private let databaseURL: URL?
    private var store: VocabularyStore?

    init(databaseURL: URL? = nil) { self.databaseURL = databaseURL }

    func list() async throws -> [VocabularyTerm] {
        try Task.checkCancellation()
        let store = try openStore()
        try Task.checkCancellation()
        return try await store.list()
    }

    func edit(_ edit: VocabularyEdit) async throws -> VocabularyEditResult {
        // 用户点击保存后写入不能因页面切换被忽略；事务结果必须反馈给控制器。
        try await openStore().edit(edit)
    }

    func recordCorrection(_ event: TermCorrection, dismissalPolicy: CorrectionDismissalPolicy) async throws -> CorrectionCountResult {
        try await openStore().recordCorrection(event, dismissalPolicy: dismissalPolicy)
    }

    func pendingCorrections() async throws -> [CorrectionCandidate] { try await openStore().pendingCorrections() }
    func decideCorrection(id: UUID, accept: Bool) async throws -> CorrectionDecisionResult {
        try await openStore().decideCorrection(id: id, accept: accept)
    }

    func saveTranscript(_ transcript: CompletedTranscript) async throws { try await openStore().saveTranscript(transcript) }
    func listTranscripts(limit: Int, offset: Int) async throws -> [CompletedTranscript] {
        try await openStore().listTranscripts(limit: limit, offset: offset)
    }

    private func openStore() throws -> VocabularyStore {
        if store == nil {
            let url = try databaseURL ?? VocabularyStore.defaultDatabaseURL()
            store = try VocabularyStore(databaseURL: url)
        }
        guard let store else { throw VocabularyFailure.storageUnavailable }
        return store
    }
}

@MainActor
final class VocabularyListController: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, automatic, manual
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "所有"
            case .automatic: return "自动添加"
            case .manual: return "手动添加"
            }
        }
        var source: VocabularySource? {
            switch self {
            case .all: return nil
            case .automatic: return .automatic
            case .manual: return .manual
            }
        }
    }

    enum State: Equatable { case idle, loading, loaded, failed(String) }
    @Published var filter: Filter = .all
    @Published var query = ""
    @Published private(set) var terms: [VocabularyTerm] = []
    @Published private(set) var state: State = .idle
    @Published var isEditorPresented = false
    @Published var draftText = ""
    @Published private(set) var editingTerm: VocabularyTerm?
    @Published private(set) var isSaving = false
    @Published private(set) var editError: String?
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published private(set) var undo: VocabularyUndo?
    private let reader: any VocabularyListing
    private var loadID: UUID?
    private var loadTask: Task<Void, Never>?

    init(reader: any VocabularyListing = LocalVocabularyReader()) { self.reader = reader }

    var isLoading: Bool { state == .loading }
    var canEdit: Bool { state == .loaded && !isSaving && reader is any VocabularyEditing }
    var canSave: Bool { !isSaving && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var visibleTerms: [VocabularyTerm] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return terms.filter { term in
            (filter.source == nil || term.source == filter.source)
            && (search.isEmpty || term.text.range(of: search, options: .caseInsensitive) != nil)
        }
    }
    var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有匹配的词条，请试试其他关键词或分类。" }
        if terms.isEmpty { return "词典还是空的。" }
        return filter == .automatic ? "还没有自动添加的词条。" : "还没有手动添加的词条。"
    }

    func reload() {
        guard !isLoading, !isSaving else { return }
        let id = UUID()
        loadID = id
        terms = []
        state = .loading
        loadTask = Task { [weak self, reader] in
            guard !Task.isCancelled, self?.loadID == id else { return }
            do {
                let terms = try await reader.list()
                guard !Task.isCancelled, let self, self.loadID == id else { return }
                self.terms = terms
                self.finish(id: id, state: .loaded)
            } catch {
                guard let self, self.loadID == id else { return }
                if Task.isCancelled || error is CancellationError { self.finish(id: id, state: .idle) }
                else { self.finish(id: id, state: .failed((error as? VocabularyFailure)?.message ?? "读取词典失败，请重试。")) }
            }
        }
    }

    func cancelLoading() {
        guard isLoading else { return }
        loadID = nil
        loadTask?.cancel(); loadTask = nil
        state = .idle
    }

    func beginAdding() {
        guard canEdit else { return }
        editingTerm = nil; draftText = ""; editError = nil
        isEditorPresented = true
    }

    func beginEditing(_ term: VocabularyTerm) {
        guard canEdit, terms.contains(term) else { return }
        editingTerm = term; draftText = term.text; editError = nil
        isEditorPresented = true
    }

    func dismissEditor() {
        guard !isSaving else { return }
        isEditorPresented = false
        draftText = ""; editingTerm = nil; editError = nil
    }

    func saveEditor() {
        guard isEditorPresented, canSave else { return }
        perform(editingTerm.map { .update($0, draftText) } ?? .add(draftText))
    }

    func deleteEditingTerm() {
        guard isEditorPresented, let editingTerm else { return }
        perform(.delete(editingTerm))
    }

    func undoLastEdit() {
        guard !isEditorPresented, let undo else { return }
        perform(.undo(undo))
    }

    func receiveAutomaticAddition(_ result: CorrectionDecisionResult) {
        if let undo = result.undo { self.undo = undo }
        cancelLoading()
        guard state == .loaded, let term = result.term else { reload(); return }
        terms.removeAll { $0.id == term.id }; terms.append(term)
        terms.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        notice = result.undo == nil ? "词典中已有这个词，保留原来的来源。" : "词条已自动添加，可以撤销。"
        noticeIsError = false
    }

    private func perform(_ edit: VocabularyEdit) {
        guard canEdit, let writer = reader as? any VocabularyEditing else { return }
        isSaving = true; editError = nil; notice = nil; noticeIsError = false
        Task { [self, writer] in
            do {
                let result = try await writer.edit(edit)
                // 不在提交后另发一次可能失败的读取，避免把“已写入”误报为保存失败。
                terms.removeAll { $0.id == result.affectedID }
                if let term = result.term {
                    terms.append(term)
                    terms.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
                    filter = .all; query = ""
                }
                switch edit {
                case .undo: undo = nil; notice = "已撤销上一次操作。"
                case .add: undo = result.undo; notice = "词条已添加。"
                case .update:
                    if let change = result.undo { undo = change }
                    notice = result.undo == nil ? "词条没有变化。" : "词条已保存。"
                case .delete: undo = result.undo; notice = "词条已删除，可以撤销。"
                }
                isSaving = false
                dismissEditor()
            } catch {
                isSaving = false
                let message = (error as? VocabularyFailure)?.message ?? "词条操作失败，请重试。"
                if isEditorPresented { editError = message }
                else { notice = message; noticeIsError = true }
            }
        }
    }

    private func finish(id: UUID, state: State) {
        guard loadID == id else { return }
        loadID = nil
        loadTask = nil
        self.state = state
    }
}
