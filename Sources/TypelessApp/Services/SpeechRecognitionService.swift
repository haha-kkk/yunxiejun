import AVFoundation
import Foundation

enum SpeechRecognitionFailure: Error, Equatable {
    case missingKey, invalidKey, invalidAudio, network, timedOut, invalidResponse, emptyText
    case http(Int)

    var message: String {
        switch self {
        case .missingKey: return "尚未保存 API 密钥，请先到设置中保存百炼北京地域的 Key。"
        case .invalidKey: return "已保存的密钥格式无效，请在设置中重新保存。"
        case .invalidAudio: return "录音文件无效、超过 3 分钟或超过 6 MB，请重新录制后再识别。"
        case .network: return "网络连接失败，请检查网络后重试。没有自动重试。"
        case .timedOut: return "识别等待超时，请检查网络后重试。已发送的请求仍可能计费。"
        case .invalidResponse: return "识别服务返回格式异常或结果不完整，请重试。"
        case .emptyText: return "没有识别到文字，请回听录音，再重新录制或识别。"
        case .http(let status):
            let reason: String
            switch status {
            case 400: reason = "识别请求参数未被服务接受，请检查接口配置；这不表示你的发音有问题"
            case 401: reason = "密钥无效或地域不匹配，请检查北京地域 Key"
            case 403: reason = "账号没有模型访问权限，请检查百炼服务开通情况"
            case 404: reason = "识别模型或接口不可用"
            case 429: reason = "请求过多或额度不足，请稍后重试并检查账号额度"
            case 300..<400: reason = "服务要求跳转地址，已停止请求"
            default: reason = "识别服务暂时不可用，请稍后重试"
            }
            return "识别失败（HTTP \(status)）：\(reason)。没有自动重试。"
        }
    }
}

protocol SpeechRecognizing: Sendable {
    func transcribe(file: URL) async throws -> String
}

struct SpeechHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

protocol SpeechHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SpeechHTTPResponse
}

/// 不跟随重定向，凭据只能发送给固定的百炼北京接口。
private final class NoSpeechRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct URLSessionSpeechTransport: SpeechHTTPTransport {
    static let maximumResponseBytes = 1_000_000
    let makeConfiguration: @Sendable () -> URLSessionConfiguration

    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.makeConfiguration = makeConfiguration
    }

    func send(_ request: URLRequest) async throws -> SpeechHTTPResponse {
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoSpeechRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpeechRecognitionFailure.invalidResponse }
        CleanupDiagnostics.current?.record(.httpReceived, httpStatus: http.statusCode)
        // 错误正文不读、不显示，避免把服务错误里的音频或凭据带到页面。
        guard http.statusCode == 200 else { return SpeechHTTPResponse(status: http.statusCode, data: Data()) }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw SpeechRecognitionFailure.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else { throw SpeechRecognitionFailure.invalidResponse }
            data.append(byte)
        }
        CleanupDiagnostics.current?.record(.bodyFinished)
        return SpeechHTTPResponse(status: http.statusCode, data: data)
    }
}

/// 保留 T08 的 WAV 格式，文件读取和 JSON/Base64 处理在 actor 上完成。
actor BailianSpeechRecognitionService: SpeechRecognizing {
    static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    static let model = "qwen3-asr-flash"
    private let keys: any APIKeyStoring
    private let transport: any SpeechHTTPTransport
    private let vocabulary: any VocabularyListing

    init(keys: any APIKeyStoring, transport: any SpeechHTTPTransport = URLSessionSpeechTransport(),
         vocabulary: any VocabularyListing = EmptyVocabularyListing()) {
        self.keys = keys
        self.transport = transport
        self.vocabulary = vocabulary
    }

    func transcribe(file: URL) async throws -> String {
        try Task.checkCancellation()
        let audio = try Self.loadAudio(file)
        guard let key = try await keys.read() else { throw SpeechRecognitionFailure.missingKey }
        guard !key.isEmpty, key.utf8.count <= 2048,
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            throw SpeechRecognitionFailure.invalidKey
        }
        try Task.checkCancellation()
        let hints = try await VocabularyHints.load(from: vocabulary)
        var messages: [[String: Any]] = []
        if let context = try hints.speechContext() {
            // Qwen ASR 的上下文必须放在 content 数组的 text 字段；字符串 content 会返回 400。
            messages.append(["role": "system", "content": [["text": context]]])
        }
        messages.append(["role": "user", "content": [[
            "type": "input_audio",
            "input_audio": ["data": "data:audio/wav;base64," + audio.base64EncodedString()]
        ]]])
        let payload: [String: Any] = [
            "model": Self.model, "stream": false, "asr_options": ["enable_itn": false],
            "messages": messages
        ]
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try Task.checkCancellation()
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else { throw SpeechRecognitionFailure.http(response.status) }
        return try Self.parse(response.data).replacingOccurrences(of: key, with: "[密钥已隐藏]")
    }

    static func loadAudio(_ url: URL) throws -> Data {
        do {
            guard url.isFileURL, url.pathExtension.lowercased() == "wav" else { throw SpeechRecognitionFailure.invalidAudio }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (45...6_000_000).contains(size) else { throw SpeechRecognitionFailure.invalidAudio }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 6_000_001), data.count == size,
                  data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
                throw SpeechRecognitionFailure.invalidAudio
            }
            let audio = try AVAudioFile(forReading: url)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0, duration <= 180,
                  audio.processingFormat.channelCount == 1 else { throw SpeechRecognitionFailure.invalidAudio }
            return data
        } catch { throw SpeechRecognitionFailure.invalidAudio }
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
              response.choices.count == 1, let choice = response.choices.first,
              choice.finish_reason == "stop", choice.message.content.utf8.count <= 16_384 else {
            throw SpeechRecognitionFailure.invalidResponse
        }
        let text = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechRecognitionFailure.emptyText }
        return text
    }
}
