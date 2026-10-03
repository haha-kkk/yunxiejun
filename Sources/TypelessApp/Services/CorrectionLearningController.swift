import Combine
import Foundation

protocol CorrectionLearning: Sendable {
    func recordCorrection(_ event: TermCorrection, dismissalPolicy: CorrectionDismissalPolicy) async throws -> CorrectionCountResult
    func pendingCorrections() async throws -> [CorrectionCandidate]
    func decideCorrection(id: UUID, accept: Bool) async throws -> CorrectionDecisionResult
}

extension VocabularyStore: CorrectionLearning {}

@MainActor
final class CorrectionLearningController: ObservableObject {
    let probe: ExternalTextProbeController
    @Published private(set) var pending: [CorrectionCandidate] = []
    @Published private(set) var lastCount: CorrectionCandidate?
    @Published private(set) var isSaving = false
    @Published private(set) var isLoading = false
    @Published private(set) var notice = "先准备测试句，再开始观察一次改词。"
    @Published private(set) var error: String?
    private let store: any CorrectionLearning
    private let dismissalPolicy: CorrectionDismissalPolicy
    private var observer = StableTermCorrection()
    private var failedEvent: TermCorrection?
    private var loadID: UUID?
    var onAccepted: ((CorrectionDecisionResult) -> Void)?
    var canSave: () -> Bool = { true }

    init(store: any CorrectionLearning, probe: ExternalTextProbeController, dismissalPolicy: CorrectionDismissalPolicy,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.probe = probe; self.dismissalPolicy = dismissalPolicy
        probe.onSample = { [weak self] sample in
            guard let self, let event = self.observer.receive(sample, now: now()) else { return }
            self.probe.stop(reason: "本轮已捕获一次稳定改词，停止读取。")
            self.record(event)
        }
        probe.onContinuityBreak = { [weak self] in self?.observer.breakContinuity() }
    }

    var canRetry: Bool { failedEvent != nil && !isSaving }

    func startObserving() {
        guard !isSaving, !probe.isRunning, failedEvent == nil else { return }
        observer.begin(); error = nil
        notice = "请切到目标输入框，停留两秒，再改一个词；改好后再等两秒。"
        probe.startSelected()
    }

    func stopObserving() { probe.stop(); observer.breakContinuity() }

    func startAfterOutput(_ context: OutputCorrectionContext) {
        guard !isSaving, !probe.isRunning, failedEvent == nil,
              context.baseline.targetPID == context.target.id else { return }
        observer.begin(baseline: context.baseline); error = nil
        notice = "已开始观察刚输出的输入框，最多 60 秒；改词后停留两秒。切走、Esc 或下次录音会停止。"
        probe.startAfterOutput(context)
    }

    func retryRecording() {
        guard let event = failedEvent, !isSaving else { return }
        record(event)
    }

    func discardFailedRecording() {
        guard !isSaving else { return }
        failedEvent = nil; error = nil; notice = "已放弃这次未保存的修改，可以重新观察。"
    }

    func reloadPending() {
        guard !isSaving, !isLoading else { return }
        isLoading = true
        let id = UUID(); loadID = id
        Task { [self] in
            do {
                let values = try await store.pendingCorrections()
                guard loadID == id else { return }
                pending = values; error = nil
            } catch {
                guard loadID == id else { return }
                self.error = message(error)
            }
            isLoading = false; loadID = nil
        }
    }

    func decide(accept: Bool) {
        guard !isSaving, let candidate = pending.first else { return }
        guard canSave() else { error = "词典正在保存其他修改，请稍后再点。"; return }
        invalidateLoad(); isSaving = true; error = nil
        stopObserving()
        Task { [self] in
            do {
                let result = try await store.decideCorrection(id: candidate.id, accept: accept)
                pending.removeAll { $0.id == candidate.id }
                if lastCount?.id == candidate.id { lastCount = result.candidate }
                notice = accept ? "已确认“\(candidate.text)”在词典中。" : "已取消添加“\(candidate.text)”。再纠正三次后重新询问。"
                if accept { onAccepted?(result) }
            } catch {
                self.error = message(error)
                if error as? CorrectionFailure == .notPending { pending.removeAll { $0.id == candidate.id } }
            }
            isSaving = false
        }
    }

    private func record(_ event: TermCorrection) {
        guard !isSaving else { return }
        invalidateLoad(); isSaving = true; error = nil
        Task { [self] in
            do {
                let result = try await store.recordCorrection(event, dismissalPolicy: dismissalPolicy)
                failedEvent = nil; lastCount = result.candidate
                notice = "“\(event.observedText)” → “\(result.candidate.text)”：累计 \(result.candidate.count) 次。"
                pending.removeAll { $0.id == result.candidate.id }
                if result.candidate.status == .pending { pending.append(result.candidate) }
            } catch {
                failedEvent = event; self.error = message(error)
            }
            isSaving = false
        }
    }

    private func invalidateLoad() { loadID = nil; isLoading = false }
    private func message(_ error: Error) -> String {
        (error as? CorrectionFailure)?.message ?? (error as? VocabularyFailure)?.message ?? "词典学习操作失败，请重试。"
    }
}
