import CSQLite
import Foundation

/// actor 串行读写连接，事务内部不跨 await 拆开。
/// 初始化同步开库；T17 接入页面时应在后台任务中创建实例。
actor VocabularyStore {
    let database: VocabularyDatabase

    static func defaultDatabaseURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VocabularyFailure.storageUnavailable
        }
        return support.appendingPathComponent("Typeless01", isDirectory: true)
            .appendingPathComponent("vocabulary.sqlite3")
    }

    // T17 接入设置页面时再打开正式路径；T16 测试只打开独立临时数据库。
    init(databaseURL: URL) throws { database = try VocabularyDatabase(url: databaseURL) }

    func close() throws { try database.close() }

    func list() throws -> [VocabularyTerm] {
        try database.statement(Self.columns + " WHERE deleted_at IS NULL ORDER BY created_at, id") { statement in
            var terms: [VocabularyTerm] = []
            while try database.step(statement) == SQLITE_ROW { terms.append(try Self.decode(statement)) }
            return terms
        }
    }

    func term(id: UUID) throws -> VocabularyTerm? {
        try database.statement(Self.columns + " WHERE id = ? AND deleted_at IS NULL", [.text(id.uuidString)]) { statement in
            guard try database.step(statement) == SQLITE_ROW else { return nil }
            return try Self.decode(statement)
        }
    }

    @discardableResult
    func add(text: String, source: VocabularySource) throws -> VocabularyTerm {
        let text = try Self.validatedText(text)
        let id = UUID(), now = Date().timeIntervalSince1970
        return try database.transaction {
            try database.execute("""
                INSERT INTO vocabulary_term (id, canonical_text, normalized_key, source, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(id.uuidString), .text(text), .text(Self.key(text)), .text(source.rawValue), .real(now), .real(now)])
            return VocabularyTerm(id: id, text: text, source: source, createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
        }
    }

    @discardableResult
    func update(id: UUID, text: String) throws -> VocabularyTerm {
        let text = try Self.validatedText(text)
        return try database.transaction {
            guard let before = try term(id: id) else { throw VocabularyFailure.notFound }
            let now = max(Date().timeIntervalSince1970, before.updatedAt.timeIntervalSince1970)
            try database.execute("UPDATE vocabulary_term SET canonical_text = ?, normalized_key = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                                 [.text(text), .text(Self.key(text)), .real(now), .text(id.uuidString)])
            return VocabularyTerm(id: id, text: text, source: before.source, createdAt: before.createdAt, updatedAt: Date(timeIntervalSince1970: now))
        }
    }

    /// 软删除保留原行。设置页使用 edit 接口，一并取得撤销所需的版本信息。
    @discardableResult
    func delete(id: UUID) throws -> VocabularyTerm {
        try database.transaction {
            guard let before = try term(id: id) else { throw VocabularyFailure.notFound }
            let now = max(Date().timeIntervalSince1970, before.updatedAt.timeIntervalSince1970)
            try database.execute("UPDATE vocabulary_term SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                                 [.real(now), .real(now), .text(id.uuidString)])
            return before
        }
    }

    /// 检查旧版本、写入和生成撤销凭据属于同一个事务，不允许旧页面覆盖更新后的词条。
    func edit(_ edit: VocabularyEdit) throws -> VocabularyEditResult {
        try database.transaction {
            switch edit {
            case .add(let input):
                let text = try Self.validatedText(input)
                // 与 SQLite 的 Unix 秒往返使用同一精度，否则 Date 的参考纪元转换
                // 可能相差一个浮点位，让刚新增的词条被误判为已经变化。
                let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970), id = UUID()
                let term = VocabularyTerm(id: id, text: text, source: .manual, createdAt: now, updatedAt: now)
                try database.execute("INSERT INTO vocabulary_term (id, canonical_text, normalized_key, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                                     [.text(id.uuidString), .text(text), .text(Self.key(text)), .text(VocabularySource.manual.rawValue), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
                return VocabularyEditResult(affectedID: id, term: term, undo: VocabularyUndo(before: nil, after: term, deleted: false))
            case .update(let expected, let input):
                try requireCurrent(expected, deleted: false)
                let text = try Self.validatedText(input)
                guard text != expected.text else {
                    return VocabularyEditResult(affectedID: expected.id, term: expected, undo: nil)
                }
                let after = try writeVersion(expected, text: text, deleted: false)
                return VocabularyEditResult(affectedID: after.id, term: after, undo: VocabularyUndo(before: expected, after: after, deleted: false))
            case .delete(let expected):
                try requireCurrent(expected, deleted: false)
                let after = try writeVersion(expected, text: expected.text, deleted: true)
                return VocabularyEditResult(affectedID: after.id, term: nil, undo: VocabularyUndo(before: expected, after: after, deleted: true))
            case .undo(let undo):
                try requireCurrent(undo.after, deleted: undo.deleted)
                if let before = undo.before {
                    guard before.id == undo.after.id, before.source == undo.after.source,
                          before.createdAt == undo.after.createdAt else { throw VocabularyFailure.invalidData }
                    let restored = try writeVersion(undo.after, text: before.text, deleted: false)
                    return VocabularyEditResult(affectedID: restored.id, term: restored, undo: nil)
                }
                guard !undo.deleted else { throw VocabularyFailure.invalidData }
                _ = try writeVersion(undo.after, text: undo.after.text, deleted: true)
                return VocabularyEditResult(affectedID: undo.after.id, term: nil, undo: nil)
            }
        }
    }

    private func requireCurrent(_ expected: VocabularyTerm, deleted: Bool) throws {
        try database.statement(Self.columns + " WHERE id = ?", [.text(expected.id.uuidString)]) { row in
            guard try database.step(row) == SQLITE_ROW, try Self.decode(row) == expected,
                  (sqlite3_column_type(row, 6) != SQLITE_NULL) == deleted else {
                throw VocabularyFailure.changedSinceEditing
            }
            if deleted {
                guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 6)),
                      sqlite3_column_double(row, 6) == expected.updatedAt.timeIntervalSince1970 else {
                    throw VocabularyFailure.changedSinceEditing
                }
            }
        }
    }

    private func writeVersion(_ before: VocabularyTerm, text: String, deleted: Bool) throws -> VocabularyTerm {
        let text = try Self.validatedText(text)
        // 即使同一时刻连续操作，也必须得到不同的版本，避免重复撤销成功。
        let now = max(Date().timeIntervalSince1970, before.updatedAt.timeIntervalSince1970.nextUp)
        let deletion = deleted ? "?" : "NULL"
        var bindings: [VocabularyBinding] = [.text(text), .text(Self.key(text)), .real(now)]
        if deleted { bindings.append(.real(now)) }
        bindings.append(.text(before.id.uuidString))
        try database.execute("UPDATE vocabulary_term SET canonical_text = ?, normalized_key = ?, updated_at = ?, deleted_at = \(deletion) WHERE id = ?", bindings)
        return VocabularyTerm(id: before.id, text: text, source: before.source, createdAt: before.createdAt, updatedAt: Date(timeIntervalSince1970: now))
    }

    private static let columns = "SELECT id, canonical_text, source, created_at, updated_at, normalized_key, deleted_at FROM vocabulary_term"

    static func validatedText(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({
            $0.value >= 32 && !(127...159).contains($0.value) && !CharacterSet.newlines.contains($0)
        }) else { throw VocabularyFailure.invalidText }
        return text
    }

    // 保留大小写及内部空格，不做同音合并。仅统一 Unicode 的等价编码。
    static func key(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    private static func decode(_ row: OpaquePointer) throws -> VocabularyTerm {
        let text = try VocabularyDatabase.text(row, 1)
        guard let id = UUID(uuidString: try VocabularyDatabase.text(row, 0)),
              let source = VocabularySource(rawValue: try VocabularyDatabase.text(row, 2)),
              (try? validatedText(text)) == text,
              try VocabularyDatabase.text(row, 5) == key(text),
              [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 3)),
              [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 4)) else {
            throw VocabularyFailure.invalidData
        }
        let created = sqlite3_column_double(row, 3), updated = sqlite3_column_double(row, 4)
        guard created.isFinite, updated.isFinite, updated >= created else { throw VocabularyFailure.invalidData }
        return VocabularyTerm(id: id, text: text, source: source, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
    }
}
