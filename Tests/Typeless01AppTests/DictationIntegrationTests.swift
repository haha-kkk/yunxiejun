import AVFoundation
import Combine
import Foundation
import Testing
@testable import Typeless01App

@MainActor
private final class FlowRecorder: DictationRecording {
    @Published var state: MicrophoneRecordingController.State = .idle
    var updates: AnyPublisher<MicrophoneRecordingController.State, Never> { $state.eraseToAnyPublisher() }
    var clipURL: URL? = URL(fileURLWithPath: "/test/audio.wav")
    var isVeryQuietClip = false
    var warnings: [String] = []
    var starts = 0
    var stops = 0
    var permissionPending = false
    func beginRecording() { starts += 1; state = permissionPending ? .requestingPermission : .recording }
    func finishRecording() { stops += 1; state = .ready }
    func deleteClip() { state = .idle }
}

actor FlowServices: SpeechRecognizing, TextCleaning, TextOutputWriting {
    enum Stage: String, CaseIterable { case recognition, cleaning, output }
    var suspended: Stage?
    var failed: Stage?
    var pending: CheckedContinuation<Void, Never>?
    var calls: [Stage] = []
    var original = "嗯，请用 Claude 整理需求，先不要发布。"
    var cleaned = "请用 Claude 整理需求，先不要发布。"
    var mismatch = false
    var field = 1
    var writes: [(Int, String)] = []
    var correction: OutputCorrectionContext?
    func attachContext(_ context: OutputCorrectionContext) { correction = context }
    func configure(suspended: Stage? = nil, failed: Stage? = nil, original: String? = nil, mismatch: Bool = false) {
        self.suspended = suspended; self.failed = failed; self.mismatch = mismatch
        if let original { self.original = original }
    }
    func resume() { pending?.resume(); pending = nil }
    func moveCursor(to field: Int) { self.field = field }
    private func enter(_ stage: Stage) async throws {
        calls.append(stage)
        if suspended == stage { await withCheckedContinuation { pending = $0 } }
        if failed == stage {
            if stage == .output { throw TextOutputFailure.noTarget }
            throw URLError(.notConnectedToInternet)
        }
    }
    func transcribe(file: URL) async throws -> String { try await enter(.recognition); return original }
    func clean(_ text: String) async throws -> TextCleanupResult {
        try await enter(.cleaning)
        return try TextCleanupResult(request: TextCleanupRequest(originalText: mismatch ? "其他会话" : text), output: cleaned)
    }
    func insert(_ text: String) async throws {
        try await enter(.output)
        try Task.checkCancellation()
        writes.append((field, text))
    }
    func insertForCorrection(_ text: String) async throws -> OutputCorrectionContext? {
        try await insert(text)
        return correction
    }
}

private func flowWait(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待集成状态超时"); throw CancellationError()
}

@Suite("I02 真实会话调度与接口交接（隔离服务）")
@MainActor
struct DictationIntegrationTests {
    private func controller(_ mic: FlowRecorder, _ services: FlowServices, timeout: Duration = .seconds(5)) -> DictationController {
        DictationController(recording: mic, recognition: services, cleaning: services, output: services,
                            processingTimeout: timeout, outputTimeout: timeout)
    }

    @Test("两次 Fn 自动走完录音、识别、整理、最终光标输入，处理期间重复 Fn 不重复请求")
    func successfulFlow() async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(suspended: .cleaning)
        let baseline = ExternalTextSnapshot(targetPID: 2, fieldID: UUID(), role: "AXTextArea", text: "Cloud")
        await services.attachContext(OutputCorrectionContext(target: ExternalTextTarget(id: 2, name: "编辑器", bundleIdentifier: "test"),
                                                            baseline: baseline, reader: FlowContextReader(sample: baseline)))
        let flow = controller(mic, services)
        var delivered: [Int32] = []
        let popup = ResultOverlayModel(); popup.connect(to: flow)
        let archiveStore = TestArchiveStore()
        let connectedArchive = TranscriptArchiveController(store: archiveStore); connectedArchive.connect(to: flow)
        flow.onOutputDelivered = { delivered.append($0.target.id) }
        flow.handleFn()
        try await flowWait { flow.overlayPhase == .recording }
        flow.handleFn()
        try await flowWait { await services.pending != nil }
        #expect(flow.overlayPhase == .processing && mic.stops == 1)
        flow.handleFn(); flow.handleFn()
        #expect(mic.starts == 1)
        await services.moveCursor(to: 2); await services.resume()
        try await flowWait { !flow.isBusy }
        #expect(await services.calls == [.recognition, .cleaning, .output])
        #expect(await services.writes.first?.0 == 2)
        #expect(flow.result?.cleanedText == "请用 Claude 整理需求，先不要发布。")
        #expect(flow.transcript.hasPrefix("嗯") && flow.didInsert && flow.overlayPhase == nil)
        #expect(mic.state == .idle)
        #expect(delivered == [2])
        #expect(popup.content == nil)
        try await flowWait { !connectedArchive.isSaving && !connectedArchive.isLoading }
        #expect(await archiveStore.records.first?.text == flow.result?.cleanedText)
    }

    @Test("录音中取消不请求 API；权限尚未返回时第二次 Fn 取消等待", arguments: [false, true])
    func cancelRecording(_ permissionPending: Bool) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        mic.permissionPending = permissionPending
        let flow = controller(mic, services)
        flow.handleFn()
        if permissionPending { flow.handleFn() } else { flow.cancel() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!flow.isBusy && flow.result == nil && flow.overlayPhase == nil)
        #expect(await services.calls.isEmpty && mic.state == .idle)
    }

    @Test("识别、整理、输出等待期间取消，迟到返回不能交付", arguments: FlowServices.Stage.allCases)
    func cancelledStage(_ stage: FlowServices.Stage) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(suspended: stage)
        let flow = controller(mic, services)
        let popup = ResultOverlayModel(); popup.connect(to: flow)
        let archiveStore = TestArchiveStore()
        let connectedArchive = TranscriptArchiveController(store: archiveStore); connectedArchive.connect(to: flow)
        flow.handleFn(); flow.handleFn()
        try await flowWait { await services.pending != nil }
        flow.cancel(); await services.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(await services.writes.isEmpty)
        #expect(!flow.isBusy && flow.result == nil && flow.transcript.isEmpty && flow.overlayPhase == nil)
        #expect(popup.content == nil)
        #expect(await archiveStore.records.isEmpty)
        #expect(!connectedArchive.isSaving)
    }

    @Test("旧请求取消后返回，不覆盖下一轮正在进行的录音")
    func staleReturn() async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(suspended: .recognition)
        let flow = controller(mic, services)
        let popup = ResultOverlayModel(); popup.connect(to: flow)
        flow.handleFn(); flow.handleFn()
        try await flowWait { await services.pending != nil }
        flow.cancel(); flow.handleFn()
        await services.resume()
        try await flowWait { flow.overlayPhase == .recording }
        #expect(flow.isRecording && flow.transcript.isEmpty)
        #expect(await services.writes.isEmpty)
        flow.cancel()
        #expect(popup.content == nil)
    }

    @Test("静音、缺少文件及录音失败不请求 API", arguments: 0..<3)
    func badRecording(_ kind: Int) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        if kind == 0 { mic.isVeryQuietClip = true }
        if kind == 1 { mic.clipURL = nil }
        let flow = controller(mic, services)
        flow.handleFn()
        if kind == 2 { mic.state = .failed("麦克风断开") } else { flow.handleFn() }
        try await flowWait { !flow.isBusy }
        #expect(await services.calls.isEmpty)
        #expect(flow.result == nil && flow.overlayPhase == nil)
    }

    @Test("空转写及错配整理结果不会进入输出", arguments: [false, true])
    func invalidResult(_ mismatch: Bool) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(original: mismatch ? nil : " \n", mismatch: mismatch)
        let flow = controller(mic, services)
        flow.handleFn(); flow.handleFn()
        try await flowWait { !flow.isBusy }
        #expect(await services.writes.isEmpty && flow.result == nil)
    }

    @Test("识别与整理失败显示错误，输入失败保留完整结果", arguments: FlowServices.Stage.allCases)
    func failure(_ stage: FlowServices.Stage) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(failed: stage)
        let flow = controller(mic, services)
        let popup = ResultOverlayModel(); popup.connect(to: flow)
        let archiveStore = TestArchiveStore()
        let archive = TranscriptArchiveController(store: archiveStore); archive.connect(to: flow)
        flow.handleFn(); flow.handleFn()
        try await flowWait { !flow.isBusy }
        #expect(await services.writes.isEmpty && !flow.didInsert)
        #expect((flow.result != nil) == (stage == .output))
        #expect(flow.overlayPhase == nil)
        #expect((popup.content != nil) == (stage == .output))
        if stage == .output { #expect(popup.content?.text == flow.result?.cleanedText) }
        try await flowWait { !archive.isSaving && !archive.isLoading }
        #expect(await archiveStore.records.count == (stage == .output ? 1 : 0))
        guard case .failed = flow.state else { Issue.record("失败不得显示已输入"); return }
    }

    @Test("各异步阶段超时结束会话且拒绝迟到写入", arguments: FlowServices.Stage.allCases)
    func timeout(_ stage: FlowServices.Stage) async throws {
        let mic = FlowRecorder(), services = FlowServices()
        await services.configure(suspended: stage)
        let flow = controller(mic, services, timeout: .milliseconds(60))
        let popup = ResultOverlayModel(); popup.connect(to: flow)
        let archiveStore = TestArchiveStore()
        let archive = TranscriptArchiveController(store: archiveStore); archive.connect(to: flow)
        flow.handleFn(); flow.handleFn()
        try await flowWait { await services.pending != nil }
        try await flowWait { !flow.isBusy }
        await services.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(flow.status.contains("超时") && flow.overlayPhase == nil)
        #expect(await services.writes.isEmpty)
        #expect((flow.result != nil) == (stage == .output))
        #expect((popup.content != nil) == (stage == .output))
        try await flowWait { !archive.isSaving && !archive.isLoading }
        #expect(await archiveStore.records.count == (stage == .output ? 1 : 0))
    }

    @Test("其他测试占用时不启动麦克风，自动结束录音也能交接")
    func exclusivityAndAutoFinish() async throws {
        let mic = FlowRecorder(), services = FlowServices()
        let flow = controller(mic, services)
        flow.canStart = { false }; flow.handleFn()
        #expect(mic.starts == 0 && !flow.isBusy)
        flow.canStart = { true }; flow.handleFn()
        mic.state = .ready // AVAudioRecorder 到达时限的自然结束通知。
        try await flowWait { !flow.isBusy }
        #expect(flow.didInsert && mic.stops == 0)
    }

    @Test("异步输出的模型编号保护：不能重复交付或在取消后完成")
    func modelOutput() throws {
        let model = DictationSession()
        let id = try #require(model.start())
        #expect(model.finishRecording(for: id)); #expect(model.complete(text: "结果", for: id))
        #expect(model.beginOutput(for: UUID()) == nil)
        #expect(model.beginOutput(for: id) == "结果")
        #expect(model.beginOutput(for: id) == nil && model.start() == nil)
        #expect(model.cancel(for: id)); #expect(!model.finishOutput(for: id))
        let next = try #require(model.start())
        #expect(!model.finishOutput(for: id))
        #expect(model.state == .recording(next))
    }

    @Test("真实 WAV、SQLite 词典、两种 API 请求格式与最终输出全链路交接（网络响应为固定夹具）")
    func realAdapters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-I02-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VocabularyStore(databaseURL: root.appendingPathComponent("terms.sqlite3"))
        try await store.add(text: "Claude", source: .manual)
        let audio = root.appendingPathComponent("fixture.wav")
        do {
            let file = try AVAudioFile(forWriting: audio, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600))
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
            try file.write(from: buffer)
        }
        let recorder = FlowRecorder(); recorder.clipURL = audio
        let transport = FlowHTTP(), writer = FlowServices()
        let flow = DictationController(recording: recorder,
            recognition: BailianSpeechRecognitionService(keys: FlowKeys(), transport: transport, vocabulary: store),
            cleaning: TextCleanupService(generator: BailianTextCleanupGenerator(keys: FlowKeys(), transport: transport), vocabulary: store),
            output: writer)
        flow.handleFn(); flow.handleFn()
        try await flowWait { !flow.isBusy }
        #expect(flow.didInsert && flow.result?.referenceTerms == ["Claude"])
        #expect(await writer.writes.first?.1 == "请用 Claude 写需求，先不要发布。")
        let requests = await transport.requests
        #expect(requests.count == 2)
        let asrBody = try #require(requests.first?.httpBody)
        let asr = try #require(JSONSerialization.jsonObject(with: asrBody) as? [String: Any])
        let messages = try #require(asr["messages"] as? [[String: Any]])
        let context = try #require(messages.first?["content"] as? [[String: String]])
        #expect(context.first?["text"]?.contains("Claude") == true)
        let input = try #require(messages.last?["content"] as? [[String: Any]])
        let encoded = try #require(input.first?["input_audio"] as? [String: String])
        let base64 = try #require(encoded["data"]?.components(separatedBy: ",").last)
        #expect(Data(base64Encoded: base64) == (try Data(contentsOf: audio)))
        let cleanupBody = try #require(requests.last?.httpBody)
        let cleanup = try #require(JSONSerialization.jsonObject(with: cleanupBody) as? [String: Any])
        let cleanupMessages = try #require(cleanup["messages"] as? [[String: String]])
        let body = try #require(cleanupMessages.last?["content"]?.data(using: .utf8))
        let original = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(original["transcript"] as? String == "嗯，请用 cloud 这个 AI 助手写需求，先不要发布。")
        #expect(original["vocabulary"] as? [String] == ["Claude"])
        try await store.close()
    }
}

private struct FlowContextReader: ExternalTextReading {
    let sample: ExternalTextSnapshot
    func read(targetPID: Int32) async -> ExternalTextReadResult { .readable(sample) }
}

private struct FlowKeys: APIKeyStoring {
    func isConfigured() async throws -> Bool { true }
    func read() async throws -> String? { "i02-fake-key" }
    func save(_ key: String) async throws {}
    func delete() async throws {}
}

private actor FlowHTTP: SpeechHTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) throws -> SpeechHTTPResponse {
        requests.append(request)
        let text = requests.count == 1 ? "嗯，请用 cloud 这个 AI 助手写需求，先不要发布。" : "请用 Claude 写需求，先不要发布。"
        return SpeechHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject:
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]))
    }
}
