import Combine
import Foundation

@MainActor
final class TextCleanupController: ObservableObject {
    enum State: Equatable {
        case idle, preparingOutput, processing, delivering, completed, cancelled
        case failed(String)
    }

    @Published var input = "" {
        didSet { if input != oldValue { reset() } }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var result: TextCleanupResult?
    @Published private(set) var outputStatus: String?
    @Published private(set) var isLocalOutputTest = false
    private let service: any TextCleaning
    private let writer: any TextOutputWriting
    private let timeout: Duration
    private let outputTimeout: Duration
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineID: UUID?

    init(service: any TextCleaning, timeout: Duration = .seconds(75),
         writer: any TextOutputWriting = FocusedTextOutputWriter(backend: MacFocusedTextOutputBackend()),
         outputTimeout: Duration = .seconds(4)) {
        self.service = service
        self.timeout = timeout
        self.writer = writer
        self.outputTimeout = outputTimeout
    }

    var isBusy: Bool { [.preparingOutput, .processing, .delivering].contains(state) }
    var status: String {
        switch state {
        case .idle: return "带入转写或粘贴文字后，点击整理。"
        case .preparingOutput: return isLocalOutputTest
            ? "5 秒后直接输入本页原文，请切换应用并点击输入位置；本次不调用 API。"
            : "5 秒后开始整理，请切到要输入文字的应用，并点击输入位置。"
        case .processing: return "正在整理表达，请稍候…"
        case .delivering: return "正在确认当前光标并输入文字…"
        case .completed: return isLocalOutputTest ? "本地输入测试结束，没有调用 API 或整理文字。" : "整理完成，请对照原文检查。"
        case .cancelled: return "已取消整理，原文仍保留；本次结果不会显示。"
        case .failed(let message): return message
        }
    }

    func begin(outputToCursor: Bool = false, preparationDelay: Duration = .seconds(5), localOutputTest: Bool = false) {
        guard !isBusy else { return }
        reset()
        isLocalOutputTest = localOutputTest
        let outputToCursor = outputToCursor || localOutputTest
        let original = input
        do { _ = try TextCleanupRequest(originalText: original) }
        catch { state = .failed(Self.message(for: error)); return }
        let id = UUID()
        requestID = id
        state = outputToCursor ? .preparingOutput : .processing
        requestTask = Task { [weak self, service, writer] in
            guard !Task.isCancelled, self?.requestID == id else { return }
            do {
                if outputToCursor { try await Task.sleep(for: preparationDelay) }
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.state = .processing
                self.startDeadline(id: id, duration: self.timeout)
                // 独立验证原生输出，不把固定原文伪装成模型整理；页面明确展示来源。
                let result: TextCleanupResult
                if localOutputTest {
                    result = try TextCleanupResult(request: TextCleanupRequest(originalText: original), output: original)
                } else {
                    result = try await service.clean(original)
                }
                guard !Task.isCancelled, self.requestID == id else { return }
                guard self.input == original, result.originalText == original else {
                    self.finish(id: id, state: .failed(TextCleanupAPIFailure.invalidResponse.message))
                    return
                }
                self.result = result
                if outputToCursor {
                    self.state = .delivering
                    self.startDeadline(id: id, duration: self.outputTimeout)
                    do {
                        try await writer.insert(result.cleanedText)
                        guard !Task.isCancelled, self.requestID == id else { return }
                        self.outputStatus = "已输入当前光标位置；本次文字仍保留在本页。"
                    } catch {
                        guard !Task.isCancelled, self.requestID == id else { return }
                        self.outputStatus = ((error as? TextOutputFailure)?.message ?? "输入失败，请检查目标输入框。")
                            + " 本次文字保留在本页，没有自动复制或重试。"
                    }
                }
                self.finish(id: id, state: .completed)
            } catch {
                guard let self, self.requestID == id else { return }
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                self.finish(id: id, state: cancelled ? .cancelled : .failed(Self.message(for: error)))
            }
        }
    }

    private func startDeadline(id: UUID, duration: Duration) {
        deadlineTask?.cancel()
        let deadlineID = UUID()
        self.deadlineID = deadlineID
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled, let self, self.requestID == id, self.deadlineID == deadlineID else { return }
            self.requestTask?.cancel()
            if self.state == .delivering {
                self.outputStatus = "输入等待超时，请先检查目标输入框，避免重复输入。本次文字保留在本页，没有自动复制或重试。"
                self.finish(id: id, state: .completed)
            } else {
                self.finish(id: id, state: .failed(Self.message(for: URLError(.timedOut))))
            }
        }
    }

    func cancelIfActive() {
        guard isBusy else { return }
        reset()
        state = .cancelled
    }

    func reset() {
        requestID = nil
        requestTask?.cancel(); requestTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        deadlineID = nil
        result = nil
        outputStatus = nil
        isLocalOutputTest = false
        state = .idle
    }

    private func finish(id: UUID, state: State) {
        guard requestID == id else { return }
        requestID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        deadlineID = nil
        requestTask = nil
        self.state = state
    }

    static func message(for error: Error) -> String {
        if let error = error as? VocabularyHintsFailure { return error.message }
        if let error = error as? VocabularyFailure { return "无法读取参考词典：" + error.message }
        if let error = error as? TextCleanupFailure { return error.message }
        if let error = error as? TextCleanupAPIFailure { return error.message }
        if let error = error as? KeychainFailure { return error.message }
        if let error = error as? URLError {
            return error.code == .timedOut
                ? "整理等待超时，原文仍保留。已发送的请求仍可能计费，没有自动重试。"
                : "网络连接失败，原文仍保留。请检查网络后重试。"
        }
        return "整理失败，原文仍保留，请重试。"
    }
}
