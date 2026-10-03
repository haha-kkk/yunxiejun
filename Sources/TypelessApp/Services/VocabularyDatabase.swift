import CSQLite
import Foundation

enum VocabularyBinding { case text(String), real(Double), integer(Int64) }

/// 连接只由 VocabularyStore 持有，所有 statement 在返回前 finalize。
final class VocabularyDatabase {
    private var handle: OpaquePointer?
    private static let applicationID = 0x54593031 // TY01

    init(url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), !url.hasDirectoryPath else { throw VocabularyFailure.invalidLocation }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw VocabularyFailure.storageUnavailable }
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, handle != nil else {
            if let handle { sqlite3_close_v2(handle) }; handle = nil
            throw VocabularyFailure.sqlite(code)
        }
        do {
            try check(sqlite3_extended_result_codes(handle, 1))
            try check(sqlite3_busy_timeout(handle, 1500))
            try execute("PRAGMA foreign_keys = ON")
            guard try integer("PRAGMA foreign_keys") == 1 else { throw VocabularyFailure.invalidData }
            try migrate()
        } catch {
            if let handle { sqlite3_close_v2(handle) }; handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func close() throws {
        guard let handle else { return }
        try check(sqlite3_close(handle))
        self.handle = nil
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrate() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            let identity = try integer("PRAGMA application_id")
            guard identity == 0 || identity == Self.applicationID else { throw VocabularyFailure.incompatibleDatabase }
            guard version <= 4 else { throw VocabularyFailure.newerSchema(version) }
            if version == 0 {
                guard try integer("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                    throw VocabularyFailure.incompatibleDatabase
                }
                try execute("""
                    CREATE TABLE vocabulary_term (
                        id TEXT PRIMARY KEY NOT NULL,
                        canonical_text TEXT NOT NULL CHECK(length(canonical_text) > 0),
                        normalized_key TEXT NOT NULL CHECK(length(normalized_key) > 0),
                        source TEXT NOT NULL CHECK(source IN ('manual', 'automatic')),
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        deleted_at REAL
                    )
                    """)
                try execute("CREATE UNIQUE INDEX vocabulary_active_key ON vocabulary_term(normalized_key) WHERE deleted_at IS NULL")
                try execute("PRAGMA application_id = \(Self.applicationID)")
            } else {
                guard version >= 1, identity == Self.applicationID else { throw VocabularyFailure.incompatibleDatabase }
                // 校验必需列存在；缺表/坏文件时明确失败，绝不自动删库重建。
                try execute("SELECT id, canonical_text, normalized_key, source, created_at, updated_at, deleted_at FROM vocabulary_term LIMIT 0")
            }
            if version < 2 {
                try execute("""
                    CREATE TABLE correction_candidate (
                        id TEXT PRIMARY KEY NOT NULL,
                        canonical_text TEXT NOT NULL CHECK(length(canonical_text) > 0),
                        normalized_key TEXT NOT NULL UNIQUE CHECK(length(normalized_key) > 0),
                        count INTEGER NOT NULL CHECK(typeof(count) = 'integer' AND count > 0),
                        updated_at REAL NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE correction_event (
                        id TEXT PRIMARY KEY NOT NULL,
                        candidate_id TEXT NOT NULL REFERENCES correction_candidate(id),
                        session_id TEXT NOT NULL,
                        observed_text TEXT NOT NULL CHECK(length(observed_text) > 0),
                        corrected_text TEXT NOT NULL CHECK(length(corrected_text) > 0),
                        created_at REAL NOT NULL
                    )
                    """)
                try execute("PRAGMA user_version = 2")
            } else {
                try execute("SELECT id, canonical_text, normalized_key, count, updated_at FROM correction_candidate LIMIT 0")
                try execute("SELECT id, candidate_id, session_id, observed_text, corrected_text, created_at FROM correction_event LIMIT 0")
            }
            if version < 3 {
                try execute("ALTER TABLE correction_candidate ADD COLUMN status TEXT NOT NULL DEFAULT 'collecting' CHECK(status IN ('collecting', 'pending', 'accepted', 'dismissed'))")
                try execute("ALTER TABLE correction_candidate ADD COLUMN decision_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(decision_count) = 'integer' AND decision_count >= 0 AND decision_count <= count)")
                try execute("UPDATE correction_candidate SET status = 'pending' WHERE count >= 3")
                try execute("UPDATE correction_candidate SET status = 'accepted', decision_count = count WHERE normalized_key IN (SELECT normalized_key FROM vocabulary_term WHERE deleted_at IS NULL)")
                try execute("PRAGMA user_version = 3")
            } else {
                try execute("SELECT status, decision_count FROM correction_candidate LIMIT 0")
            }
            if version < 4 {
                try execute("""
                    CREATE TABLE completed_transcript (
                        id TEXT PRIMARY KEY NOT NULL,
                        final_text TEXT NOT NULL CHECK(length(final_text) > 0),
                        created_at REAL NOT NULL
                    )
                    """)
                try execute("CREATE INDEX completed_transcript_date ON completed_transcript(created_at DESC, id DESC)")
                try execute("PRAGMA user_version = 4")
            } else {
                try execute("SELECT id, final_text, created_at FROM completed_transcript LIMIT 0")
            }
        }
    }

    func execute(_ sql: String, _ bindings: [VocabularyBinding] = []) throws {
        try statement(sql, bindings) { row in
            guard try step(row) == SQLITE_DONE else { throw VocabularyFailure.invalidData }
        }
    }

    private func integer(_ sql: String) throws -> Int {
        try statement(sql) { row in
            guard try step(row) == SQLITE_ROW else { throw VocabularyFailure.invalidData }
            return Int(sqlite3_column_int(row, 0))
        }
    }

    func statement<T>(_ sql: String, _ bindings: [VocabularyBinding] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw VocabularyFailure.closed }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw VocabularyFailure.invalidData }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): try check(value.withCString { typeless_bind_text(statement, index, $0) })
            case .real(let value): try check(sqlite3_bind_double(statement, index, value))
            case .integer(let value): try check(sqlite3_bind_int64(statement, index, value))
            }
        }
        return try body(statement)
    }

    func step(_ row: OpaquePointer) throws -> Int32 {
        let code = sqlite3_step(row)
        if code != SQLITE_ROW && code != SQLITE_DONE { try check(code) }
        return code
    }

    static func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(row, column),
              let value = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8) else {
            throw VocabularyFailure.invalidData
        }
        return value
    }

    private func check(_ code: Int32) throws {
        guard code != SQLITE_OK else { return }
        // UNIQUE 扩展错误码；不把其他约束失败都误报成重复词条。
        if code == (SQLITE_CONSTRAINT | (8 << 8)) { throw VocabularyFailure.duplicate }
        throw VocabularyFailure.sqlite(code)
    }
}
