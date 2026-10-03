import Foundation

enum TextCleanupFailure: Error, Equatable {
    case emptyInput, inputTooLong, emptyOutput, outputTooLong

    var message: String {
        switch self {
        case .emptyInput: return "没有可整理的文字，请先完成语音识别。"
        case .inputTooLong: return "这段文字超过当前整理长度上限，请先分成较短的内容。"
        case .emptyOutput: return "整理服务没有返回文字，原始转写仍保留。"
        case .outputTooLong: return "整理服务返回的文字过长，本次结果未采用。"
        }
    }
}

struct TextCleanupMessage: Equatable, Sendable, Encodable {
    enum Role: String, Sendable, Encodable { case system, user }
    let role: Role
    let content: String
}

struct TextCleanupRequest: Sendable {
    // T11 原始结果限制为 16 KiB；这是防异常输入的字节上限，不是长文验收规则。
    static let maximumInputBytes = 16_384
    let originalText: String
    let promptVersion: String
    let messages: [TextCleanupMessage]
    let referenceTerms: [String]

    init(originalText: String, hints: VocabularyHints? = nil) throws {
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextCleanupFailure.emptyInput
        }
        guard originalText.utf8.count <= Self.maximumInputBytes else { throw TextCleanupFailure.inputTooLong }
        self.originalText = originalText
        referenceTerms = hints?.terms ?? []
        if !referenceTerms.isEmpty {
            struct Content: Encodable { let transcript: String; let vocabulary: [String] }
            let data = try JSONEncoder().encode(Content(transcript: originalText, vocabulary: referenceTerms))
            promptVersion = TextCleanupPrompt.vocabularyVersion
            messages = [TextCleanupMessage(role: .system, content: TextCleanupPrompt.withVocabulary),
                        TextCleanupMessage(role: .user, content: String(decoding: data, as: UTF8.self))]
            return
        }
        promptVersion = TextCleanupPrompt.version
        // 规则和原话分成不同消息；原话原样传递，不拼进 system 提示词。
        messages = [TextCleanupMessage(role: .system, content: TextCleanupPrompt.system),
                    TextCleanupMessage(role: .user, content: originalText)]
    }
}

struct TextCleanupResult: Equatable, Sendable {
    // 允许短内容补标点后比输入略长；不把长度比例当成语义保真判定。
    static let maximumOutputBytes = 32_768
    let originalText: String
    let cleanedText: String
    let promptVersion: String
    let referenceTerms: [String]

    init(request: TextCleanupRequest, output: String) throws {
        guard output.utf8.count <= Self.maximumOutputBytes else { throw TextCleanupFailure.outputTooLong }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TextCleanupFailure.emptyOutput }
        originalText = request.originalText
        cleanedText = cleaned
        promptVersion = request.promptVersion
        referenceTerms = request.referenceTerms
    }
}

/// T14 才提供网络实现；协议本身不读密钥、不请求 API。
protocol TextCleanupGenerating: Sendable {
    func generate(_ request: TextCleanupRequest) async throws -> String
}

protocol TextCleaning: Sendable {
    func clean(_ originalText: String) async throws -> TextCleanupResult
}

struct TextCleanupService: TextCleaning {
    let generator: any TextCleanupGenerating
    let vocabulary: any VocabularyListing
    let diagnostics: @Sendable (CleanupDiagnostics.Event) -> Void

    init(generator: any TextCleanupGenerating, vocabulary: any VocabularyListing = EmptyVocabularyListing(),
         diagnostics: @escaping @Sendable (CleanupDiagnostics.Event) -> Void = CleanupDiagnostics().sink) {
        self.generator = generator; self.vocabulary = vocabulary
        self.diagnostics = diagnostics
    }

    func clean(_ originalText: String) async throws -> TextCleanupResult {
        let trace = CleanupDiagnostics(sink: diagnostics)
        return try await CleanupDiagnostics.$current.withValue(trace) {
            try await withTaskCancellationHandler {
                trace.record(.started)
                do {
                    let result = try await cleanTraced(originalText)
                    trace.record(.completed)
                    return result
                } catch {
                    trace.record(.failed)
                    throw error
                }
            } onCancel: { trace.record(.cancellationRequested) }
        }
    }

    private func cleanTraced(_ originalText: String) async throws -> TextCleanupResult {
        try Task.checkCancellation()
        _ = try TextCleanupRequest(originalText: originalText) // 无效输入不读词典、不调用生成器。
        let hints = try await VocabularyHints.load(from: vocabulary)
        CleanupDiagnostics.current?.record(.vocabularyFinished)
        let request = try TextCleanupRequest(originalText: originalText, hints: hints)
        let output = try await generator.generate(request)
        // 即使实现没有响应取消，也不能把已经取消的结果当作成功交出。
        try Task.checkCancellation()
        return try TextCleanupResult(request: request, output: output)
    }
}
