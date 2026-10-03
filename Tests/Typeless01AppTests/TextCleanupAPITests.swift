import Foundation
import Security
import Testing
@testable import Typeless01App

private actor CleanupAPIKeys: APIKeyStoring {
    var key: String?
    var error: Error?
    init(_ key: String?) { self.key = key }
    func isConfigured() -> Bool { key != nil }
    func read() throws -> String? { if let error { throw error }; return key }
    func save(_ key: String) { self.key = key }
    func delete() { key = nil }
    func fail(_ error: Error) { self.error = error }
}

private actor WaitingCleanupKeys: APIKeyStoring {
    private var pending: CheckedContinuation<String?, Never>?
    var isWaiting: Bool { pending != nil }
    func isConfigured() -> Bool { true }
    func read() async -> String? { await withCheckedContinuation { pending = $0 } }
    func save(_ key: String) {}
    func delete() {}
    func authorize() { pending?.resume(returning: "test-key"); pending = nil }
}

private func cleanupJSON(_ text: String, finish: String = "stop") -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": text]]]])
}

private actor CleanupAPITransport: SpeechHTTPTransport {
    var requests: [URLRequest] = []
    let response: SpeechHTTPResponse
    var error: Error?
    init(status: Int = 200, data: Data = cleanupJSON("预算十五元，不是五十元。")) {
        response = SpeechHTTPResponse(status: status, data: data)
    }
    func send(_ request: URLRequest) throws -> SpeechHTTPResponse {
        requests.append(request)
        if let error { throw error }
        return response
    }
    func fail(_ error: Error) { self.error = error }
}

@Suite("T14 整理 API（虚构密钥和隔离响应）")
struct TextCleanupAPITests {
    @Test("完整接口沿用固定模型和北京地址、关闭思考、分离原文和规则")
    func requestContract() async throws {
        let transport = CleanupAPITransport()
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: CleanupAPIKeys("test-key"), transport: transport))
        let original = "嗯，预算十五元，不是五十元。"
        let result = try await service.clean(original)
        #expect(result.originalText == original)
        #expect(result.cleanedText == "预算十五元，不是五十元。")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == BailianSpeechRecognitionService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen3.7-flash-2026-07-15")
        #expect(body["enable_thinking"] as? Bool == false)
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_completion_tokens"] as? Int == 4096)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": TextCleanupPrompt.system], ["role": "user", "content": original]])
    }

    @Test("未保存或非法密钥在联网前停止")
    func missingOrInvalidKey() async throws {
        let input = try TextCleanupRequest(originalText: "文字")
        for key: String? in [nil, "", "bad\nkey", "中文", String(repeating: "x", count: 2049)] {
            let transport = CleanupAPITransport()
            await #expect(throws: key == nil ? TextCleanupAPIFailure.missingKey : .invalidKey) {
                try await BailianTextCleanupGenerator(keys: CleanupAPIKeys(key), transport: transport).generate(input)
            }
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test("钥匙串拒绝访问保留原错误，不能当作未配置")
    func deniedKeychain() async throws {
        let keys = CleanupAPIKeys("unused")
        await keys.fail(KeychainFailure(status: errSecAuthFailed))
        let transport = CleanupAPITransport()
        await #expect(throws: KeychainFailure.self) {
            try await TextCleanupService(generator: BailianTextCleanupGenerator(keys: keys, transport: transport)).clean("文字")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("等待钥匙串时已取消，之后授权也不能补发网络请求")
    func cancelledBeforeKeyAuthorization() async throws {
        let keys = WaitingCleanupKeys()
        let transport = CleanupAPITransport()
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: keys, transport: transport))
        let task = Task { try await service.clean("原文") }
        for _ in 0..<2000 {
            if await keys.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        let wasWaiting = await keys.isWaiting
        await keys.authorize()
        #expect(wasWaiting)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    @Test("HTTP 错误只请求一次，不把错误正文当成结果")
    func httpErrors() async {
        for code in [301, 401, 403, 404, 429, 500] {
            let transport = CleanupAPITransport(status: code, data: Data("sensitive-body".utf8))
            await #expect(throws: TextCleanupAPIFailure.http(code)) {
                try await TextCleanupService(generator: BailianTextCleanupGenerator(keys: CleanupAPIKeys("unused"), transport: transport)).clean("文字")
            }
            #expect(await transport.requests.count == 1)
            #expect(!TextCleanupAPIFailure.http(code).message.contains("sensitive-body"))
        }
    }

    @Test("输出截断、坏 JSON、异常结果类型和过大响应不交付")
    func invalidResponses() async throws {
        #expect(throws: TextCleanupAPIFailure.incompleteOutput) { try BailianTextCleanupGenerator.parse(cleanupJSON("半句话", finish: "length")) }
        #expect(throws: TextCleanupAPIFailure.incompleteOutput) { try BailianTextCleanupGenerator.parse(cleanupJSON("", finish: "content_filter")) }
        for data in [Data("bad".utf8), Data("{\"choices\":[]}".utf8), Data("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":null}}]}".utf8), Data(repeating: 120, count: 1_000_001)] {
            #expect(throws: TextCleanupAPIFailure.invalidResponse) { try BailianTextCleanupGenerator.parse(data) }
        }
        #expect(throws: TextCleanupFailure.outputTooLong) { try BailianTextCleanupGenerator.parse(cleanupJSON(String(repeating: "x", count: 32_769))) }
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: CleanupAPIKeys("unused"), transport: CleanupAPITransport(data: cleanupJSON(" \n"))))
        await #expect(throws: TextCleanupFailure.emptyOutput) { try await service.clean("原文") }
    }

    @Test("网络和共用传输层错误映射准确，不重试")
    func networkErrors() async {
        let transport = CleanupAPITransport()
        await transport.fail(URLError(.notConnectedToInternet))
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: CleanupAPIKeys("unused"), transport: transport))
        await #expect(throws: URLError.self) { try await service.clean("原文") }
        await transport.fail(SpeechRecognitionFailure.invalidResponse)
        await #expect(throws: TextCleanupAPIFailure.invalidResponse) { try await service.clean("原文") }
        #expect(await transport.requests.count == 2)
    }

    @Test("意外回显密钥时隐藏密钥，保留原文")
    func redaction() async throws {
        let result = try await TextCleanupService(generator: BailianTextCleanupGenerator(
            keys: CleanupAPIKeys("test-secret"), transport: CleanupAPITransport(data: cleanupJSON("unexpected test-secret")))).clean("原文")
        #expect(result.cleanedText == "unexpected [密钥已隐藏]")
        #expect(result.originalText == "原文")
    }
}

private actor ControlledTextCleaner: TextCleaning {
    var calls: [String] = []
    var pending: [CheckedContinuation<TextCleanupResult, Error>] = []
    func clean(_ originalText: String) async throws -> TextCleanupResult {
        calls.append(originalText)
        // 故意不响应取消，验证控制器仍拒绝迟到结果。
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(original: String, output: String) throws {
        pending.removeFirst().resume(returning: try TextCleanupResult(request: TextCleanupRequest(originalText: original), output: output))
    }
    func fail(_ error: Error) { pending.removeFirst().resume(throwing: error) }
}

@Suite("T14 整理页面状态、取消和恢复")
@MainActor
struct TextCleanupControllerTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("等待测试状态超时")
        throw CancellationError()
    }

    @Test("输入校验不请求；同步占位拒绝重复点击，成功保留原文")
    func beginAndSuccess() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        for input in ["", " \n", String(repeating: "x", count: 16_385)] {
            controller.input = input; controller.begin()
            #expect(!controller.isBusy)
        }
        #expect(await service.calls.isEmpty)
        controller.input = "嗯，预算十五元。"
        controller.begin(); controller.begin()
        #expect(controller.isBusy)
        try await waitUntil { await service.calls.count == 1 }
        try await service.complete(original: controller.input, output: "预算十五元。")
        try await waitUntil { !controller.isBusy }
        #expect(controller.state == .completed)
        #expect(controller.input == "嗯，预算十五元。")
        #expect(controller.result?.cleanedText == "预算十五元。")
    }

    @Test("立即关窗或切页取消，不产生请求且原文保留")
    func immediateCancel() async {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "原文"; controller.begin(); controller.cancelIfActive()
        for _ in 0..<20 { await Task.yield() }
        #expect(await service.calls.isEmpty)
        #expect(controller.state == .cancelled)
        #expect(controller.input == "原文")
        #expect(controller.result == nil)
    }

    @Test("取消后重试，旧的完成不能覆盖新请求")
    func staleSuccess() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "原文"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        controller.cancelIfActive(); controller.begin()
        try await waitUntil { await service.calls.count == 2 }
        try await service.complete(original: "原文", output: "旧结果")
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.isBusy && controller.result == nil)
        try await service.complete(original: "原文", output: "新结果")
        try await waitUntil { !controller.isBusy }
        #expect(controller.result?.cleanedText == "新结果")
    }

    @Test("改动原文立即清除旧结果并失效进行中请求")
    func editsInvalidateResults() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "第一段"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        controller.input = "第二段"
        try await service.complete(original: "第一段", output: "迟到结果")
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.state == .idle && controller.result == nil)
        controller.begin()
        try await waitUntil { await service.calls.count == 2 }
        try await service.complete(original: "第二段", output: "第二段结果")
        try await waitUntil { !controller.isBusy }
        controller.input = "修改过"
        #expect(controller.result == nil && controller.state == .idle)
    }

    @Test("错误不伪装成功，原文保留并可重试")
    func retry() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "原文"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        await service.fail(URLError(.notConnectedToInternet))
        try await waitUntil { !controller.isBusy }
        #expect(controller.status.contains("网络"))
        #expect(controller.result == nil && controller.input == "原文")
        controller.begin()
        try await waitUntil { await service.calls.count == 2 }
        try await service.complete(original: "原文", output: "整理完成")
        try await waitUntil { !controller.isBusy }
        #expect(controller.state == .completed)
    }

    @Test("超时释放按钮，之后的错误不能覆盖超时状态")
    func timeout() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service, timeout: .milliseconds(50))
        controller.input = "原文"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        try await waitUntil { !controller.isBusy }
        #expect(controller.status.contains("超时"))
        await service.fail(TextCleanupAPIFailure.http(500))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.status.contains("超时") && controller.result == nil)
        #expect(controller.input == "原文")
    }

    @Test("拒绝不属于本次原文的返回结果")
    func mismatchedSource() async throws {
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "当前原文"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        try await service.complete(original: "其他原文", output: "错误的结果")
        try await waitUntil { !controller.isBusy }
        #expect(controller.result == nil)
        #expect(controller.state == .failed(TextCleanupAPIFailure.invalidResponse.message))
    }

    @Test("错误提示不回显未知底层正文，取消错误不显示成功")
    func cancellationAndSafeError() async throws {
        #expect(TextCleanupController.message(for: NSError(domain: "secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret"])) == "整理失败，原文仍保留，请重试。")
        let service = ControlledTextCleaner()
        let controller = TextCleanupController(service: service)
        controller.input = "原文"; controller.begin()
        try await waitUntil { await service.calls.count == 1 }
        await service.fail(URLError(.cancelled))
        try await waitUntil { !controller.isBusy }
        #expect(controller.state == .cancelled && controller.result == nil)
    }
}
