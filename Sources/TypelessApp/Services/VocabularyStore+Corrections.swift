import CSQLite
import Foundation

extension VocabularyStore {
    /// T20 只登记调用方明确提供的词语对；T19 的全文采样不能直接传进来计数。
    /// 事件去重与候选计数在一个事务内完成，跨连接写入也不会漏计或重复计。
    func recordCorrection(_ event: TermCorrection, dismissalPolicy: CorrectionDismissalPolicy = .afterThreeNewCorrections) throws -> CorrectionCountResult {
        let observed = try Self.validatedText(event.observedText)
        let corrected = try Self.validatedText(event.correctedText)
        guard Self.key(observed) != Self.key(corrected) else { throw CorrectionFailure.unchanged }
        return try database.transaction {
            if let candidateID = try existingCorrection(event, observed: observed, corrected: corrected) {
                guard let candidate = try candidate(where: "id = ?", value: candidateID),
                      Self.key(candidate.text) == Self.key(corrected) else {
                    throw VocabularyFailure.invalidData
                }
                return CorrectionCountResult(candidate: candidate, recorded: false)
            }

            let previous = try correctionCandidate(for: corrected)
            guard previous?.count != Int64.max else { throw CorrectionFailure.countOverflow }
            let now = max(Date().timeIntervalSince1970, previous?.updatedAt.timeIntervalSince1970 ?? -Double.infinity)
            let count = (previous?.count ?? 0) + 1
            var status = previous?.status ?? .collecting
            let decisionCount = previous?.decisionCount ?? 0
            if (status == .collecting && count >= 3)
                || (status == .dismissed && dismissalPolicy == .afterThreeNewCorrections && count - decisionCount >= 3) {
                status = .pending
            }
            if try activeTerm(for: corrected) != nil { status = .accepted }
            let candidate = CorrectionCandidate(
                id: previous?.id ?? UUID(), text: previous?.text ?? corrected,
                count: count, updatedAt: Date(timeIntervalSince1970: now), status: status, decisionCount: decisionCount
            )
            if previous == nil {
                try database.execute("INSERT INTO correction_candidate (id, canonical_text, normalized_key, count, updated_at, status, decision_count) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                     [.text(candidate.id.uuidString), .text(candidate.text), .text(Self.key(corrected)), .integer(candidate.count), .real(now), .text(status.rawValue), .integer(decisionCount)])
            } else {
                try database.execute("UPDATE correction_candidate SET count = ?, updated_at = ?, status = ? WHERE id = ?",
                                     [.integer(candidate.count), .real(now), .text(status.rawValue), .text(candidate.id.uuidString)])
            }
            try database.execute("INSERT INTO correction_event (id, candidate_id, session_id, observed_text, corrected_text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.text(event.id.uuidString), .text(candidate.id.uuidString), .text(event.sessionID.uuidString), .text(observed), .text(corrected), .real(now)])
            return CorrectionCountResult(candidate: candidate, recorded: true)
        }
    }

    func correctionCandidate(for text: String) throws -> CorrectionCandidate? {
        try candidate(where: "normalized_key = ?", value: Self.key(Self.validatedText(text)))
    }

    func pendingCorrections() throws -> [CorrectionCandidate] {
        try database.statement("SELECT id FROM correction_candidate WHERE status = 'pending' ORDER BY updated_at, id") { row in
            var results: [CorrectionCandidate] = []
            while try database.step(row) == SQLITE_ROW {
                guard let item = try candidate(where: "id = ?", value: VocabularyDatabase.text(row, 0)) else { throw VocabularyFailure.invalidData }
                results.append(item)
            }
            return results
        }
    }

    /// 确认状态和正式词条同一事务提交；中途失败仍保持待确认，供用户重试。
    func decideCorrection(id: UUID, accept: Bool) throws -> CorrectionDecisionResult {
        try database.transaction {
            guard let before = try candidate(where: "id = ?", value: id.uuidString), before.status == .pending else {
                throw CorrectionFailure.notPending
            }
            let now = max(Date().timeIntervalSince1970, before.updatedAt.timeIntervalSince1970)
            var term: VocabularyTerm?, undo: VocabularyUndo?
            if accept {
                term = try activeTerm(for: before.text)
                if term == nil {
                    let newID = UUID(), date = Date(timeIntervalSince1970: now)
                    let added = VocabularyTerm(id: newID, text: before.text, source: .automatic, createdAt: date, updatedAt: date)
                    try database.execute("INSERT INTO vocabulary_term (id, canonical_text, normalized_key, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                                         [.text(newID.uuidString), .text(before.text), .text(Self.key(before.text)), .text(VocabularySource.automatic.rawValue), .real(now), .real(now)])
                    term = added; undo = VocabularyUndo(before: nil, after: added, deleted: false)
                }
            }
            let status: CorrectionStatus = accept ? .accepted : .dismissed
            try database.execute("UPDATE correction_candidate SET status = ?, decision_count = count, updated_at = ? WHERE id = ?",
                                 [.text(status.rawValue), .real(now), .text(id.uuidString)])
            let after = CorrectionCandidate(id: id, text: before.text, count: before.count, updatedAt: Date(timeIntervalSince1970: now), status: status, decisionCount: before.count)
            return CorrectionDecisionResult(candidate: after, term: term, undo: undo)
        }
    }

    private func activeTerm(for text: String) throws -> VocabularyTerm? {
        try database.statement("SELECT id FROM vocabulary_term WHERE normalized_key = ? AND deleted_at IS NULL", [.text(Self.key(text))]) { row in
            guard try database.step(row) == SQLITE_ROW else { return nil }
            guard let id = UUID(uuidString: try VocabularyDatabase.text(row, 0)) else { throw VocabularyFailure.invalidData }
            return try term(id: id)
        }
    }

    private func existingCorrection(_ event: TermCorrection, observed: String, corrected: String) throws -> String? {
        try database.statement("SELECT candidate_id, session_id, observed_text, corrected_text FROM correction_event WHERE id = ?", [.text(event.id.uuidString)]) { row in
            guard try database.step(row) == SQLITE_ROW else { return nil }
            let id = try VocabularyDatabase.text(row, 0)
            guard UUID(uuidString: id) != nil else { throw VocabularyFailure.invalidData }
            guard try VocabularyDatabase.text(row, 1) == event.sessionID.uuidString,
                  Self.key(try VocabularyDatabase.text(row, 2)) == Self.key(observed),
                  Self.key(try VocabularyDatabase.text(row, 3)) == Self.key(corrected) else {
                throw CorrectionFailure.conflictingEvent
            }
            return id
        }
    }

    // 条件只由上面两个固定调用点给出，用户文字始终通过参数绑定。
    private func candidate(where condition: String, value: String) throws -> CorrectionCandidate? {
        try database.statement("SELECT id, canonical_text, normalized_key, count, updated_at, status, decision_count FROM correction_candidate WHERE \(condition)", [.text(value)]) { row in
            guard try database.step(row) == SQLITE_ROW else { return nil }
            let text = try VocabularyDatabase.text(row, 1)
            guard let id = UUID(uuidString: try VocabularyDatabase.text(row, 0)),
                  (try? Self.validatedText(text)) == text,
                  try VocabularyDatabase.text(row, 2) == Self.key(text),
                  sqlite3_column_type(row, 3) == SQLITE_INTEGER,
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 4)),
                  let status = CorrectionStatus(rawValue: try VocabularyDatabase.text(row, 5)),
                  sqlite3_column_type(row, 6) == SQLITE_INTEGER else {
                throw VocabularyFailure.invalidData
            }
            let count = sqlite3_column_int64(row, 3), updated = sqlite3_column_double(row, 4)
            let decided = sqlite3_column_int64(row, 6)
            guard count > 0, updated.isFinite, decided >= 0, decided <= count,
                  status != .pending || count >= 3 else { throw VocabularyFailure.invalidData }
            return CorrectionCandidate(id: id, text: text, count: count, updatedAt: Date(timeIntervalSince1970: updated), status: status, decisionCount: decided)
        }
    }
}
