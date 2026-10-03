import Combine
import Foundation

@MainActor
final class SpeechRecognitionController: ObservableObject {
    enum State: Equatable {
        case idle, processing, completed, cancelled
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    private let service: any SpeechRecognizing
    private let timeout: Duration
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(service: any SpeechRecognizing, timeout: Duration = .seconds(75)) {
        self.service = service
        self.timeout = timeout
    }

    var isBusy: Bool { state == .processing }
    var status: String {
        switch state {
        case .idle: return "录完后点击识别，将显示原始转写。"
        case .processing: return "正在识别，请稍候…"
        case .completed: return "识别完成 · 原始转写"
        case .cancelled: return "识别已取消，录音仍保留；本次结果不会显示。"
        case .failed(let message): return message
        }
    }

    func begin(file: URL?) {
        guard !isBusy else { return }
        reset()
        guard let file else { state = .failed("请先完成一段录音，再点击识别。"); return }
        let id = UUID()
        requestID = id
        state = .processing
        requestTask = Task { [weak self, service] in
            guard !Task.isCancelled, self?.requestID == id else { return }
            do {
                let text = try await service.transcribe(file: file)
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(id: id, state: .failed(SpeechRecognitionFailure.emptyText.message))
                    return
                }
                self.text = text
                self.finish(id: id, state: .completed)
            } catch {
                guard let self, self.requestID == id else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.finish(id: id, state: .cancelled)
                } else {
                    self.finish(id: id, state: .failed(Self.message(for: error)))
                }
            }
        }
        deadlineTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.requestID == id else { return }
            self.requestTask?.cancel()
            self.finish(id: id, state: .failed(SpeechRecognitionFailure.timedOut.message))
        }
    }

    func cancelIfActive() {
        guard isBusy else { return }
        reset()
        state = .cancelled
    }

    func reset() {
        requestID = nil // 先失效编号，再取消任务，迟到结果不能覆盖下一轮。
        requestTask?.cancel(); requestTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        text = ""
        state = .idle
    }

    private func finish(id: UUID, state: State) {
        guard requestID == id else { return }
        requestID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        requestTask = nil
        self.state = state
    }

    static func message(for error: Error) -> String {
        if let error = error as? VocabularyHintsFailure { return error.message }
        if let error = error as? VocabularyFailure { return "无法读取参考词典：" + error.message }
        if let error = error as? SpeechRecognitionFailure { return error.message }
        if let error = error as? KeychainFailure { return error.message }
        if let error = error as? URLError {
            return error.code == .timedOut ? SpeechRecognitionFailure.timedOut.message : SpeechRecognitionFailure.network.message
        }
        return "识别失败，请重试。" // 不显示任意服务/系统异常正文。
    }
}
