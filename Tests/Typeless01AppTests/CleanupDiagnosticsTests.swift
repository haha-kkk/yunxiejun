import Foundation
import Testing
@testable import Typeless01App

private final class DiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CleanupDiagnostics.Event] = []
    func append(_ event: CleanupDiagnostics.Event) { lock.withLock { storage.append(event) } }
    var values: [CleanupDiagnostics.Event] { lock.withLock { storage } }
}
private actor DiagnosticKeys: APIKeyStoring {
    func read() -> String? { "synthetic-secret-NEVER-LOG" }
    func isConfigured() -> Bool { true }
    func save(_ key: String) {}
    func delete() {}
}
private final class DiagnosticProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"synthetic-output-NEVER-LOG"}}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct CancellationGenerator: TextCleanupGenerating {
    func generate(_ request: TextCleanupRequest) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "late-output-NEVER-LOG"
    }
}
private struct DiagnosticError: Error {}
private struct FailingGenerator: TextCleanupGenerating {
    func generate(_ request: TextCleanupRequest) throws -> String { throw DiagnosticError() }
}

@Suite("整理阶段诊断（离线，无真实凭据或联网）")
struct CleanupDiagnosticsTests {
    @Test("实际网络适配器阶段完整且日志只含允许字段")
    func safeStages() async throws {
        let events = DiagnosticEvents()
        let transport = URLSessionSpeechTransport(makeConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticProtocol.self]
            return configuration
        })
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: DiagnosticKeys(), transport: transport),
                                         diagnostics: { events.append($0) })
        let result = try await service.clean("synthetic-input-NEVER-LOG")
        #expect(result.cleanedText == "synthetic-output-NEVER-LOG")
        let values = events.values
        #expect(values.map(\.stage) == [.started, .vocabularyFinished, .keychainStarted, .keychainFinished,
                                        .networkStarted, .httpReceived, .bodyFinished, .completed])
        #expect(Set(values.map(\.id)).count == 1)
        #expect(values.first { $0.stage == .httpReceived }?.httpStatus == 200)
        for event in values {
            #expect(event.elapsedMilliseconds >= 0)
            #expect(event.line.range(of: #"^id=[A-F0-9-]+ stage=[A-Za-z]+ elapsed_ms=[0-9]+( http_status=[0-9]+)?$"#,
                                     options: .regularExpression) != nil)
            for forbidden in ["synthetic-input", "synthetic-output", "synthetic-secret", "Bearer", "https", "Authorization"] {
                #expect(!event.line.contains(forbidden))
            }
        }
        #expect(CleanupDiagnostics.current == nil)
    }
    @Test("取消记录关联状态，不能记录成功或交出迟到结果")
    func cancelled() async throws {
        let events = DiagnosticEvents()
        let service = TextCleanupService(generator: CancellationGenerator(), diagnostics: { events.append($0) })
        let task = Task { try await service.clean("synthetic-input-NEVER-LOG") }
        while !events.values.contains(where: { $0.stage == .vocabularyFinished }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let stages = events.values.map(\.stage)
        #expect(stages.contains(.cancellationRequested))
        #expect(stages.contains(.failed))
        #expect(!stages.contains(.completed))
        #expect(Set(events.values.map(\.id)).count == 1)
    }
    @Test("普通失败与取消不同，独立请求有独立ID")
    func failed() async {
        let events = DiagnosticEvents()
        let service = TextCleanupService(generator: FailingGenerator(), diagnostics: { events.append($0) })
        for _ in 0..<2 {
            await #expect(throws: DiagnosticError.self) { try await service.clean("synthetic-input-NEVER-LOG") }
        }
        #expect(Set(events.values.map(\.id)).count == 2)
        #expect(events.values.filter { $0.stage == .failed }.count == 2)
        #expect(!events.values.contains { $0.stage == .cancellationRequested || $0.stage == .completed })
    }
}
