import Foundation
import OSLog

/// No free-form text, errors, URLs, headers or request/response data are accepted.
struct CleanupDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case started, vocabularyFinished, keychainStarted, keychainFinished
        case networkStarted, httpReceived, bodyFinished, completed, failed, cancellationRequested
    }
    struct Event: Sendable {
        let id: UUID
        let stage: Stage
        let elapsedMilliseconds: Int
        let httpStatus: Int?
        var line: String {
            "id=\(id.uuidString) stage=\(stage.rawValue) elapsed_ms=\(elapsedMilliseconds)"
                + (httpStatus.map { " http_status=\($0)" } ?? "")
        }
    }
    @TaskLocal static var current: CleanupDiagnostics?
    private static let logger = Logger(subsystem: "local.typeless01.app", category: "cleanup-diagnostics")
    let id = UUID()
    private let started = ContinuousClock.now
    let sink: @Sendable (Event) -> Void
    init(sink: @escaping @Sendable (Event) -> Void = { event in
        logger.info("\(event.line, privacy: .public)")
    }) { self.sink = sink }
    func record(_ stage: Stage, httpStatus: Int? = nil) {
        let duration = started.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        sink(Event(id: id, stage: stage, elapsedMilliseconds: Int(milliseconds), httpStatus: httpStatus))
    }
}
