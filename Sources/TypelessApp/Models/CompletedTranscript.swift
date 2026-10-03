import Foundation

struct CompletedTranscript: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
}

protocol TranscriptArchiving: Sendable {
    func saveTranscript(_ transcript: CompletedTranscript) async throws
    func listTranscripts(limit: Int, offset: Int) async throws -> [CompletedTranscript]
}
