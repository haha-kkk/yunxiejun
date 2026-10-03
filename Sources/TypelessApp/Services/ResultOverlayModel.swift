import AppKit
import Combine

/// 只展示已经结束、但未能确认写入的会话；不接管正在输出的文字。
@MainActor
final class ResultOverlayModel: ObservableObject {
    struct Content: Equatable, Identifiable {
        let id: UUID
        let text: String
        let notice: String
    }

    @Published private(set) var content: Content?
    @Published private(set) var copyStatus = ""
    private var dismissedID: UUID?
    private var observation: AnyCancellable?
    private var expiration: Task<Void, Never>?
    private let lifetime: Duration
    private let waitForExpiry: @Sendable (Duration) async throws -> Void
    var openArchive: () -> Void = {}
    private let writeClipboard: (String) -> Bool

    init(lifetime: Duration = .seconds(600),
         waitForExpiry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         writeClipboard: @escaping (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.writeClipboard = writeClipboard
        self.lifetime = lifetime
        self.waitForExpiry = waitForExpiry
    }

    func connect(to dictation: DictationController) {
        observation = dictation.$state.sink { [weak self, weak dictation] state in
            guard let dictation else { return }
            // state 最后赋值；@Published 通知发生在赋值前，必须使用传入的新状态。
            self?.receive(state: state, result: dictation.result, status: dictation.status)
        }
    }

    func receive(state: DictationSession.State, result: TextCleanupResult?, status: String) {
        guard case .failed(let id, let reason) = state,
              reason == .outputFailed || reason == .timedOut,
              let result, !result.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            expiration?.cancel(); expiration = nil
            content = nil; copyStatus = ""
            return
        }
        guard dismissedID != id else { return }
        let next = Content(id: id, text: result.cleanedText, notice: status)
        guard content != next else { return }
        let isNew = content?.id != id
        copyStatus = ""; content = next
        if isNew {
            expiration?.cancel()
            expiration = Task { [weak self, lifetime, waitForExpiry] in
                do { try await waitForExpiry(lifetime) } catch { return }
                guard let self, !Task.isCancelled, self.content?.id == id else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        expiration?.cancel(); expiration = nil
        if let id = content?.id { dismissedID = id }
        content = nil; copyStatus = ""
    }

    func copy() {
        guard let content else { return }
        copyStatus = writeClipboard(content.text) ? "已复制" : "复制失败，请重新点击“复制”。"
    }
}
