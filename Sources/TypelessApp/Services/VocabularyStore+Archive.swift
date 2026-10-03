import CSQLite
import Foundation

extension VocabularyStore: TranscriptArchiving {
    func saveTranscript(_ transcript: CompletedTranscript) throws {
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !transcript.text.contains("\0"), transcript.createdAt.timeIntervalSince1970.isFinite else {
            throw VocabularyFailure.invalidData
        }
        try database.transaction {
            // 会话编号防止重复归档；冲突时不覆盖已保存的正文或时间。
            let existing = try database.statement("SELECT final_text FROM completed_transcript WHERE id = ?", [.text(transcript.id.uuidString)]) { row -> String? in
                guard try database.step(row) == SQLITE_ROW else { return nil }
                return try VocabularyDatabase.text(row, 0)
            }
            if let existing {
                guard existing == transcript.text else { throw VocabularyFailure.invalidData }
                return
            }
            try database.execute("INSERT INTO completed_transcript (id, final_text, created_at) VALUES (?, ?, ?)",
                                 [.text(transcript.id.uuidString), .text(transcript.text), .real(transcript.createdAt.timeIntervalSince1970)])
        }
    }

    func listTranscripts(limit: Int, offset: Int) throws -> [CompletedTranscript] {
        guard (1...100).contains(limit), offset >= 0 else { throw VocabularyFailure.invalidData }
        return try database.statement("SELECT id, final_text, created_at FROM completed_transcript ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
                                      [.integer(Int64(limit)), .integer(Int64(offset))]) { row in
            var results: [CompletedTranscript] = []
            while try database.step(row) == SQLITE_ROW {
                guard let id = UUID(uuidString: try VocabularyDatabase.text(row, 0)),
                      [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 2)) else { throw VocabularyFailure.invalidData }
                let text = try VocabularyDatabase.text(row, 1), time = sqlite3_column_double(row, 2)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, time.isFinite else { throw VocabularyFailure.invalidData }
                results.append(CompletedTranscript(id: id, text: text, createdAt: Date(timeIntervalSince1970: time)))
            }
            return results
        }
    }
}
