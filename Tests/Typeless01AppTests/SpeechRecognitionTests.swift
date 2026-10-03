import AVFoundation
import Foundation
import Security
import Testing
@testable import Typeless01App

private actor SpeechTestKeys: APIKeyStoring {
    var key: String?
    var error: Error?
    init(_ key: String?) { self.key = key }
    func isConfigured() -> Bool { key != nil }
    func read() throws -> String? { if let error { throw error }; return key }
    func save(_ key: String) { self.key = key }
    func delete() { key = nil }
    func fail(_ error: Error) { self.error = error }
}

private actor SpeechTestTransport: SpeechHTTPTransport {
    var requests: [URLRequest] = []
    let response: SpeechHTTPResponse
    var error: Error?
    init(status: Int = 200, data: Data = speechJSON("请帮我整理一下 Claude 的产品需求。")) {
        response = SpeechHTTPResponse(status: status, data: data)
    }
    func send(_ request: URLRequest) throws -> SpeechHTTPResponse {
        requests.append(request)
        if let error { throw error }
        return response
    }
    func fail(_ error: Error) { self.error = error }
}

private func speechJSON(_ text: String, finish: String = "stop") -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "choices": [["finish_reason": finish, "message": ["content": text]]]
    ])
}

/// 生成与 T08 相同的 44.1 kHz、单声道、16 位 WAV，不使用真人录音。
private func speechFixture(seconds: Double = 1, sampleRate: Double = 44_100) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                  AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
    try file.write(from: buffer)
    return url
}

@Suite("T11 识别接口（隔离网络和虚构密钥）")
struct SpeechRecognitionServiceTests {
    @Test("T08 WAV 原样进入固定北京接口，请求保持原始转写参数")
    func payloadAndResult() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let transport = SpeechTestTransport()
        let service = BailianSpeechRecognitionService(keys: SpeechTestKeys("disposable-key"), transport: transport)
        let text = try await service.transcribe(file: file)
        #expect(text == "请帮我整理一下 Claude 的产品需求。")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer disposable-key")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == "qwen3-asr-flash")
        #expect(body["stream"] as? Bool == false)
        #expect((body["asr_options"] as? [String: Bool])?["enable_itn"] == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let data = try #require((content.first?["input_audio"] as? [String: String])?["data"])
        #expect(data == "data:audio/wav;base64," + (try Data(contentsOf: file)).base64EncodedString())
    }

    @Test("缺失和非法密钥不发送网络请求")
    func keyFailures() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        for key: String? in [nil, "", "bad\nkey", "非ASCII", String(repeating: "x", count: 2049)] {
            let transport = SpeechTestTransport()
            let service = BailianSpeechRecognitionService(keys: SpeechTestKeys(key), transport: transport)
            await #expect(throws: key == nil ? SpeechRecognitionFailure.missingKey : .invalidKey) {
                try await service.transcribe(file: file)
            }
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test("钥匙串拒绝访问不会假装没有配置，也不发送请求")
    func lockedKeychain() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let keys = SpeechTestKeys("unused")
        await keys.fail(KeychainFailure(status: errSecAuthFailed))
        let transport = SpeechTestTransport()
        await #expect(throws: KeychainFailure.self) {
            try await BailianSpeechRecognitionService(keys: keys, transport: transport).transcribe(file: file)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("不存在、空文件、坏格式、过大、过长、符号链接音频不上传")
    func invalidAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SpeechRecognitionFailure.invalidAudio) { try BailianSpeechRecognitionService.loadAudio(url) }
        for data in [Data(), Data(repeating: 0, count: 100), Data(repeating: 0, count: 6_000_001)] {
            try data.write(to: url)
            #expect(throws: SpeechRecognitionFailure.invalidAudio) { try BailianSpeechRecognitionService.loadAudio(url) }
        }
        let long = try speechFixture(seconds: 181, sampleRate: 16_000); defer { try? FileManager.default.removeItem(at: long) }
        #expect(throws: SpeechRecognitionFailure.invalidAudio) { try BailianSpeechRecognitionService.loadAudio(long) }
        let link = url.deletingPathExtension().appendingPathExtension("link.wav")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: long)
        #expect(throws: SpeechRecognitionFailure.invalidAudio) { try BailianSpeechRecognitionService.loadAudio(link) }
        let transport = SpeechTestTransport()
        await #expect(throws: SpeechRecognitionFailure.invalidAudio) {
            try await BailianSpeechRecognitionService(keys: SpeechTestKeys("unused"), transport: transport).transcribe(file: url)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("HTTP 错误每次只请求一次，错误正文不进入结果")
    func httpFailures() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        for code in [301, 401, 403, 404, 429, 500] {
            let transport = SpeechTestTransport(status: code, data: Data("private error body".utf8))
            await #expect(throws: SpeechRecognitionFailure.http(code)) {
                try await BailianSpeechRecognitionService(keys: SpeechTestKeys("test"), transport: transport).transcribe(file: file)
            }
            #expect(await transport.requests.count == 1)
            #expect(!SpeechRecognitionFailure.http(code).message.contains("private"))
        }
    }

    @Test("网络失败保留可识别错误类型，不自动重试")
    func networkFailures() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .cancelled] {
            let transport = SpeechTestTransport(); await transport.fail(URLError(code))
            await #expect(throws: URLError.self) {
                try await BailianSpeechRecognitionService(keys: SpeechTestKeys("test"), transport: transport).transcribe(file: file)
            }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test("空文本、坏 JSON、输出截断、异常类型和超长结果均拒绝")
    func responseValidation() throws {
        #expect(throws: SpeechRecognitionFailure.emptyText) { try BailianSpeechRecognitionService.parse(speechJSON(" \n")) }
        for data in [Data("bad".utf8), Data("{\"choices\":[]}".utf8),
                     Data("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":null}}]}".utf8),
                     speechJSON("partial", finish: "length"), speechJSON(String(repeating: "x", count: 16_385)),
                     Data(repeating: 0, count: 1_000_001)] {
            #expect(throws: SpeechRecognitionFailure.invalidResponse) { try BailianSpeechRecognitionService.parse(data) }
        }
        #expect(try BailianSpeechRecognitionService.parse(speechJSON("十五元，不是五十元。先不要发布。")) == "十五元，不是五十元。先不要发布。")
    }

    @Test("服务意外回显凭据时遮盖凭据")
    func redactedResult() async throws {
        let file = try speechFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let service = BailianSpeechRecognitionService(keys: SpeechTestKeys("private-test-key"),
            transport: SpeechTestTransport(data: speechJSON("unexpected private-test-key")))
        #expect(try await service.transcribe(file: file) == "unexpected [密钥已隐藏]")
    }
}

private actor ControlledSpeechService: SpeechRecognizing {
    var pending: [CheckedContinuation<String, Error>] = []
    var calls = 0
    func transcribe(file: URL) async throws -> String {
        calls += 1
        // 故意忽略 Task.cancel，验证远端迟到响应仍会被控制器拦住。
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ result: Result<String, Error>) { pending.removeFirst().resume(with: result) }
}

@Suite("T11 识别状态、取消和恢复")
@MainActor
struct SpeechRecognitionControllerTests {
    let file = URL(fileURLWithPath: "/unused-test.wav")

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("等待测试状态超时")
        throw CancellationError()
    }

    @Test("点击后立即关窗或切页，尚未开始的任务不能发送请求")
    func immediatelyCancel() async {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service)
        controller.begin(file: file)
        controller.cancelIfActive()
        for _ in 0..<20 { await Task.yield() }
        #expect(await service.calls == 0)
        #expect(controller.state == .cancelled)
    }

    @Test("没有音频立即提示；同步占位防止连续点击发送两次")
    func missingAndDuplicate() async throws {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service)
        controller.begin(file: nil)
        #expect(!controller.isBusy)
        #expect(controller.status.contains("先完成"))
        controller.begin(file: file); controller.begin(file: file)
        #expect(controller.isBusy)
        try await waitUntil { await service.calls == 1 }
        await service.complete(.success("Claude"))
        try await waitUntil { !controller.isBusy }
        #expect(controller.state == .completed)
        #expect(controller.text == "Claude")
        #expect(await service.calls == 1)
    }

    @Test("取消旧请求并立即重试，旧结果不能完成或覆盖新请求")
    func cancelAndLateReply() async throws {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service)
        controller.begin(file: file)
        try await waitUntil { await service.calls == 1 }
        controller.cancelIfActive()
        #expect(controller.state == .cancelled)
        #expect(controller.text.isEmpty)
        controller.begin(file: file)
        try await waitUntil { await service.calls == 2 }
        await service.complete(.success("旧文字"))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.isBusy)
        #expect(controller.text.isEmpty)
        await service.complete(.success("新文字"))
        try await waitUntil { !controller.isBusy }
        #expect(controller.text == "新文字")
        controller.reset()
        #expect(controller.text.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test("取消后即使服务迟到报错，也不覆盖已取消状态")
    func lateFailure() async throws {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service)
        controller.begin(file: file)
        try await waitUntil { await service.calls == 1 }
        controller.cancelIfActive()
        await service.complete(.failure(SpeechRecognitionFailure.http(500)))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.state == .cancelled)
        #expect(controller.text.isEmpty)
    }

    @Test("超时释放按钮，迟到结果不显示")
    func timeout() async throws {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service, timeout: .milliseconds(50))
        controller.begin(file: file)
        try await waitUntil { await service.calls == 1 }
        try await waitUntil { !controller.isBusy }
        #expect(controller.state == .failed(SpeechRecognitionFailure.timedOut.message))
        await service.complete(.success("不应出现"))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.text.isEmpty)
        #expect(controller.status.contains("超时"))
    }

    @Test("失败后可以重试，旧文字清空，空响应不伪装成功")
    func retryAfterFailures() async throws {
        let service = ControlledSpeechService()
        let controller = SpeechRecognitionController(service: service)
        let outcomes: [Result<String, Error>] = [.success("第一次"), .failure(URLError(.notConnectedToInternet)), .success(" \n"), .success("最后一次")]
        for (index, outcome) in outcomes.enumerated() {
            controller.begin(file: file)
            #expect(controller.text.isEmpty)
            try await waitUntil { await service.calls == index + 1 }
            await service.complete(outcome)
            try await waitUntil { !controller.isBusy }
            if index == 1 { #expect(controller.status.contains("网络")) }
            if index == 2 { #expect(controller.status.contains("没有识别到文字")) }
        }
        #expect(controller.text == "最后一次")
    }

    @Test("未知错误不把可能含凭据的异常正文展示出来")
    func safeError() {
        let error = NSError(domain: "sensitive-key", code: 1, userInfo: [NSLocalizedDescriptionKey: "sensitive-key"])
        #expect(SpeechRecognitionController.message(for: error) == "识别失败，请重试。")
        #expect(SpeechRecognitionController.message(for: URLError(.timedOut)).contains("超时"))
    }
}

/// 拦截 URLSession 请求；不存在 DNS、外部网络或真实 API Key 访问。
private final class SpeechStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "speech.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let kind = request.url!.lastPathComponent
        if kind == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = kind == "oversize" ? Data(repeating: 120, count: 1_000_001) : speechJSON("测试文字")
        let headers = kind == "oversize-header" ? ["Content-Length": "1000001"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: kind == "denied" ? 401 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("T11 URLSession 本地协议测试")
struct SpeechRecognitionTransportTests {
    let transport = URLSessionSpeechTransport(makeConfiguration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechStubURLProtocol.self]
        return configuration
    })
    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://speech.invalid/" + path)!)
    }

    @Test("真实 URLSession 读出合法响应，HTTP 错误不读错误正文")
    func response() async throws {
        let response = try await transport.send(request("ok"))
        #expect(response.status == 200)
        #expect(try BailianSpeechRecognitionService.parse(response.data) == "测试文字")
        let denied = try await transport.send(request("denied"))
        #expect(denied.status == 401)
        #expect(denied.data.isEmpty)
    }

    @Test("已知长度和未声明长度的过大响应都停止读取")
    func responseLimits() async {
        for kind in ["oversize", "oversize-header"] {
            await #expect(throws: SpeechRecognitionFailure.invalidResponse) { try await transport.send(request(kind)) }
        }
    }

    @Test("URLSession 断网错误正确传回控制器")
    func offline() async {
        await #expect(throws: URLError.self) { try await transport.send(request("offline")) }
    }
}
