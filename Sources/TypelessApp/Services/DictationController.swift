import Combine
import Foundation

@MainActor
protocol DictationRecording: AnyObject {
    var state: MicrophoneRecordingController.State { get }
    var updates: AnyPublisher<MicrophoneRecordingController.State, Never> { get }
    var clipURL: URL? { get }
    var isVeryQuietClip: Bool { get }
    var warnings: [String] { get }
    func beginRecording()
    func finishRecording()
    func deleteClip()
}

extension MicrophoneRecordingController: DictationRecording {
    var updates: AnyPublisher<State, Never> { $state.eraseToAnyPublisher() }
}

/// 真实 Fn 入口的唯一调度者；测试页面的控制器不参与本会话的数据交接。
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationSession.State = .idle
    @Published private(set) var overlayPhase: SessionOverlayPhase?
    @Published private(set) var status = "开启监听后，按 Fn 开始说话。"
    @Published private(set) var transcript = ""
    @Published private(set) var result: TextCleanupResult?
    @Published private(set) var notice: String?
    @Published private(set) var didInsert = false
    var canStart: () -> Bool = { true }
    var onWillStart: () -> Void = {}
    var onOutputDelivered: (OutputCorrectionContext) -> Void = { _ in }

    private let session = DictationSession()
    private let recording: any DictationRecording
    private let recognition: any SpeechRecognizing
    private let cleaning: any TextCleaning
    private let output: any TextOutputWriting
    private let processingTimeout: Duration
    private let outputTimeout: Duration
    private var activeID: UUID?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var deadlineID: UUID?
    private var observation: AnyCancellable?

    init(recording: any DictationRecording, recognition: any SpeechRecognizing,
         cleaning: any TextCleaning, output: any TextOutputWriting,
         processingTimeout: Duration = .seconds(180), outputTimeout: Duration = .seconds(4)) {
        self.recording = recording; self.recognition = recognition
        self.cleaning = cleaning; self.output = output
        self.processingTimeout = processingTimeout; self.outputTimeout = outputTimeout
        observation = recording.updates.sink { [weak self] value in
            guard let id = self?.activeID else { return }
            // @Published 在赋值前通知；等本次赋值结束再读音频属性，并携带原会话编号。
            Task { @MainActor [weak self] in self?.recordingChanged(value, id: id) }
        }
    }

    var isBusy: Bool { activeID != nil }
    var isRecording: Bool { if case .recording = state { return true }; return false }

    func handleFn() {
        if isRecording {
            if recording.state == .recording { recording.finishRecording() }
            else if recording.state == .requestingPermission { cancel() }
            return
        }
        guard !isBusy else { return } // 识别、整理和输出期间重复 Fn 不新开会话。
        guard canStart() else { status = "请先结束正在运行的单项测试，再开始语音输入。"; return }
        guard let id = session.start() else { return }
        onWillStart()
        activeID = id; transcript = ""; result = nil; notice = nil; didInsert = false
        status = "正在准备麦克风…"; state = session.state; overlayPhase = nil
        recording.beginRecording()
    }

    func cancel() {
        guard let id = activeID, session.cancel(for: id) else { return }
        // 先使会话失效，再停止录音、网络和定时器；旧回调不得接管新会话。
        activeID = nil; work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil; deadlineID = nil
        recording.deleteClip()
        transcript = ""; result = nil; didInsert = false
        state = session.state; overlayPhase = nil
        status = "已取消本次语音输入。"
        retainCleanupWarning()
    }

    private func recordingChanged(_ value: MicrophoneRecordingController.State, id: UUID) {
        guard activeID == id, case .recording(let recordingID) = session.state, recordingID == id else { return }
        switch value {
        case .requestingPermission:
            status = "等待麦克风授权；尚未开始收音。"
        case .recording:
            status = "正在录音；再按 Fn 结束，本次最多 3 分钟。"
            overlayPhase = .recording
        case .ready:
            guard let file = recording.clipURL else {
                fail(.recordingFailed, "没有取得有效录音，请重新开始。", id: id); return
            }
            guard !recording.isVeryQuietClip else {
                fail(.recordingFailed, "录音音量太低或接近静音，未上传。请检查麦克风后重新录制。", id: id); return
            }
            notice = recording.warnings.isEmpty ? nil : recording.warnings.joined(separator: "\n")
            process(file: file, id: id)
        case .failed(let message): fail(.recordingFailed, message, id: id)
        case .cancelled: cancel()
        default: break
        }
    }

    private func process(file: URL, id: UUID) {
        guard session.finishRecording(for: id) else { return }
        state = session.state; overlayPhase = .processing
        status = "正在识别语音…"
        startDeadline(id: id, duration: processingTimeout, outputStage: false)
        work = Task { [weak self, recognition, cleaning, output] in
            do {
                let original = try await recognition.transcribe(file: file)
                guard let self, self.isCurrent(id) else { return }
                guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.fail(.emptyResult, SpeechRecognitionFailure.emptyText.message, id: id); return
                }
                self.transcript = original
                self.status = "正在整理表达…"
                self.startDeadline(id: id, duration: self.processingTimeout, outputStage: false)
                let result = try await cleaning.clean(original)
                guard self.isCurrent(id) else { return }
                guard result.originalText == original else {
                    self.fail(.processingFailed, "整理返回的内容与本次原文不匹配，未输出。", id: id); return
                }
                guard self.session.complete(text: result.cleanedText, for: id),
                      let text = self.session.beginOutput(for: id) else { return }
                self.result = result; self.state = self.session.state
                self.status = "正在输入最终光标位置…"
                self.startDeadline(id: id, duration: self.outputTimeout, outputStage: true)
                do {
                    let correction = try await output.insertForCorrection(text)
                    guard self.isCurrent(id), self.session.finishOutput(for: id) else { return }
                    self.didInsert = true
                    self.status = "已输入最终光标位置；没有自动发送消息。"
                    self.finishResources(); self.state = self.session.state
                    if let correction { self.onOutputDelivered(correction) }
                } catch {
                    guard self.isCurrent(id) else { return }
                    self.fail(.outputFailed, ((error as? TextOutputFailure)?.message ?? "输入失败，请检查目标输入框。")
                              + " 完整结果保留在本窗口，可手动复制；没有自动复制或重试。", id: id)
                }
            } catch {
                guard let self, self.isCurrent(id) else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.cancel()
                } else {
                    let message = self.transcript.isEmpty
                        ? SpeechRecognitionController.message(for: error)
                        : TextCleanupController.message(for: error)
                    self.fail(.processingFailed, message, id: id)
                }
            }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { activeID == id && !Task.isCancelled }

    private func startDeadline(id: UUID, duration: Duration, outputStage: Bool) {
        deadline?.cancel()
        let token = UUID(); deadlineID = token
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.activeID == id, self.deadlineID == token else { return }
            self.work?.cancel()
            self.fail(.timedOut, outputStage
                      ? "输入等待超时，请先检查目标，避免重复输入。完整结果保留在本窗口。"
                      : "处理等待超时，已停止本次会话；没有自动重试。已发出的请求仍可能计费。", id: id)
        }
    }

    private func fail(_ reason: DictationSession.Failure, _ message: String, id: UUID) {
        guard activeID == id, session.fail(reason, for: id) else { return }
        work?.cancel()
        status = message; finishResources(); state = session.state
    }

    private func finishResources() {
        activeID = nil; work = nil
        deadline?.cancel(); deadline = nil; deadlineID = nil
        overlayPhase = nil
        recording.deleteClip()
        retainCleanupWarning()
    }

    private func retainCleanupWarning() {
        if case .failed(let message) = recording.state {
            notice = [notice, message].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
