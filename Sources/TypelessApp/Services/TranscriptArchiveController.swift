import AppKit
import Combine

@MainActor
final class TranscriptArchiveController: ObservableObject {
    @Published private(set) var entries: [CompletedTranscript] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var copyStatus = ""
    var openWindow: () -> Void = {}

    private let store: any TranscriptArchiving
    private let writeClipboard: (String) -> Bool
    private var observation: AnyCancellable?
    private var pending: [UUID: CompletedTranscript] = [:]
    private var saving: Set<UUID> = []
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?
    private let pageSize = 50

    init(store: any TranscriptArchiving, writeClipboard: @escaping (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.store = store; self.writeClipboard = writeClipboard
    }

    func connect(to dictation: DictationController) {
        observation = dictation.$state.sink { [weak self, weak dictation] state in
            self?.receive(state: state, result: dictation?.result)
        }
    }

    func receive(state: DictationSession.State, result: TextCleanupResult?) {
        guard let result else { return }
        let id: UUID
        switch state {
        case .completed(let value, _): id = value
        case .failed(let value, let reason) where reason == .outputFailed || reason == .timedOut: id = value
        default: return // 等待输出时仍可取消，不能提前保存。
        }
        guard pending[id] == nil else { return }
        let entry = CompletedTranscript(id: id, text: result.cleanedText, createdAt: Date())
        pending[id] = entry
        save(entry)
    }

    func retrySaving() {
        for entry in pending.values where !saving.contains(entry.id) { save(entry) }
    }

    private func save(_ entry: CompletedTranscript) {
        guard saving.insert(entry.id).inserted else { return }
        isSaving = true
        Task { [weak self, store] in
            do {
                try await store.saveTranscript(entry)
                guard let self else { return }
                self.pending.removeValue(forKey: entry.id)
                self.saving.remove(entry.id); self.isSaving = !self.saving.isEmpty
                if self.pending.isEmpty { self.saveError = nil }
                self.reload()
            } catch {
                guard let self else { return }
                self.saving.remove(entry.id); self.isSaving = !self.saving.isEmpty
                self.saveError = "有结果未能保存到归档，请点击“重试保存”。退出应用会丢失这些未保存结果。"
            }
        }
    }

    func reload() { load(append: false) }
    func loadMore() { guard !isLoading, hasMore else { return }; load(append: true) }

    private func load(append: Bool) {
        loadTask?.cancel()
        let id = UUID(), offset = append ? entries.count : 0
        loadID = id; isLoading = true; loadError = nil
        loadTask = Task { [weak self, store, pageSize] in
            do {
                let page = try await store.listTranscripts(limit: pageSize, offset: offset)
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                if append { self.entries.append(contentsOf: page) } else { self.entries = page }
                self.hasMore = page.count == pageSize; self.isLoading = false
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.loadError = "归档读取失败，请点击“刷新”重试。"; self.isLoading = false
            }
        }
    }

    func copy(_ entry: CompletedTranscript) {
        copyStatus = writeClipboard(entry.text) ? "已复制所选记录。" : "复制失败，请重新点击。"
    }
}
