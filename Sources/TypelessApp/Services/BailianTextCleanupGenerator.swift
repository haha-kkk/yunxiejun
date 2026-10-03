import Foundation

enum TextCleanupAPIFailure: Error, Equatable {
    case missingKey, invalidKey, invalidResponse, incompleteOutput
    case http(Int)

    var message: String {
        switch self {
        case .missingKey: return "尚未保存 API 密钥，请先到设置中保存百炼北京地域的 Key。"
        case .invalidKey: return "已保存的密钥格式无效，请在设置中重新保存。"
        case .invalidResponse: return "整理服务返回格式异常，本次结果未采用，原文仍保留。"
        case .incompleteOutput: return "整理结果未完整返回，本次结果未采用。请分成较短内容后重试。"
        case .http(let code):
            let reason: String
            switch code {
            case 401: reason = "密钥无效或地域不匹配，请检查北京地域 Key"
            case 403: reason = "账号没有模型访问权限"
            case 404: reason = "整理模型或接口不可用"
            case 429: reason = "请求过多或额度不足，请稍后重试并检查账号额度"
            case 300..<400: reason = "服务要求跳转地址，已停止请求"
            default: reason = "整理服务暂时不可用，请稍后重试"
            }
            return "整理失败（HTTP \(code)）：\(reason)。没有自动重试。"
        }
    }
}

actor BailianTextCleanupGenerator: TextCleanupGenerating {
    static let model = "qwen3.7-flash-2026-07-15"
    private let keys: any APIKeyStoring
    // 复用 T11 已验证的固定 HTTPS 网络层：不缓存、不跳转、限制响应大小。
    private let transport: any SpeechHTTPTransport

    init(keys: any APIKeyStoring, transport: any SpeechHTTPTransport = URLSessionSpeechTransport()) {
        self.keys = keys
        self.transport = transport
    }

    func generate(_ input: TextCleanupRequest) async throws -> String {
        try Task.checkCancellation()
        CleanupDiagnostics.current?.record(.keychainStarted)
        let storedKey = try await keys.read()
        CleanupDiagnostics.current?.record(.keychainFinished)
        guard let key = storedKey else { throw TextCleanupAPIFailure.missingKey }
        guard !key.isEmpty, key.utf8.count <= 2048,
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            throw TextCleanupAPIFailure.invalidKey
        }
        try Task.checkCancellation()
        struct Payload: Encodable {
            let model = BailianTextCleanupGenerator.model
            let stream = false
            let enable_thinking = false
            let max_completion_tokens = 4096
            let messages: [TextCleanupMessage]
        }
        var request = URLRequest(url: BailianSpeechRecognitionService.endpoint,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(messages: input.messages))
        let response: SpeechHTTPResponse
        CleanupDiagnostics.current?.record(.networkStarted)
        do { response = try await transport.send(request) }
        catch is SpeechRecognitionFailure { throw TextCleanupAPIFailure.invalidResponse }
        try Task.checkCancellation()
        guard response.status == 200 else { throw TextCleanupAPIFailure.http(response.status) }
        return try Self.parse(response.data).replacingOccurrences(of: key, with: "[密钥已隐藏]")
    }

    static func parse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
                let finish_reason: String
            }
            let choices: [Choice]
        }
        guard data.count <= URLSessionSpeechTransport.maximumResponseBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.choices.count == 1, let choice = response.choices.first else {
            throw TextCleanupAPIFailure.invalidResponse
        }
        guard choice.finish_reason == "stop" else { throw TextCleanupAPIFailure.incompleteOutput }
        guard choice.message.content.utf8.count <= TextCleanupResult.maximumOutputBytes else {
            throw TextCleanupFailure.outputTooLong
        }
        return choice.message.content
    }
}
