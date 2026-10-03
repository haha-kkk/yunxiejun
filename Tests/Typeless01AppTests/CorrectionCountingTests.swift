import CSQLite
import Foundation
import Testing
@testable import Typeless01App

private struct CorrectionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T20-\(UUID().uuidString)", isDirectory: true)
    var url: URL { directory.appendingPathComponent("vocabulary.sqlite3") }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

private final class RawCorrectionDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = sqlite3_open(url.path, &handle)
        guard code == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw VocabularyFailure.sqlite(code)
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw VocabularyFailure.sqlite(code) }
    }
    func integer(_ sql: String) throws -> Int64 {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &row, nil) == SQLITE_OK else { throw VocabularyFailure.invalidData }
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw VocabularyFailure.invalidData }
        return sqlite3_column_int64(row, 0)
    }
    func createV1() throws {
        try execute("""
            PRAGMA application_id = 0x54593031;
            PRAGMA user_version = 1;
            CREATE TABLE vocabulary_term (
                id TEXT PRIMARY KEY NOT NULL,
                canonical_text TEXT NOT NULL CHECK(length(canonical_text) > 0),
                normalized_key TEXT NOT NULL CHECK(length(normalized_key) > 0),
                source TEXT NOT NULL CHECK(source IN ('manual', 'automatic')),
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                deleted_at REAL
            );
            CREATE UNIQUE INDEX vocabulary_active_key ON vocabulary_term(normalized_key) WHERE deleted_at IS NULL;
            INSERT INTO vocabulary_term VALUES
                ('11111111-1111-1111-1111-111111111111', 'Claude', 'Claude', 'manual', 100, 101, NULL),
                ('22222222-2222-2222-2222-222222222222', 'DeepSeek', 'DeepSeek', 'automatic', 100, 102, NULL),
                ('33333333-3333-3333-3333-333333333333', '已删词', '已删词', 'manual', 100, 103, 103);
            """)
    }
}

@Suite("T20 术语纠正计数（真实隔离 SQLite 文件）")
struct CorrectionCountingTests {
    private func event(_ before: String = "Cloud", _ after: String = "Claude", id: UUID = UUID(), session: UUID = UUID()) -> TermCorrection {
        TermCorrection(id: id, sessionID: session, observedText: before, correctedText: after)
    }

    @Test("验收：三种错法累计 1、2、3，重新打开仍为 3，不同目标分别计数")
    func acceptanceAndPersistence() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await store.correctionCandidate(for: "Claude") == nil)
        for (index, before) in ["Cloud", "Cloude", "Cloud AI"].enumerated() {
            let result = try await store.recordCorrection(event(before))
            #expect(result.recorded && result.candidate.count == Int64(index + 1))
            print("T20：\(before) → Claude，累计 \(result.candidate.count) 次。")
        }
        let expected = try await store.correctionCandidate(for: "Claude")
        #expect(try await store.list().isEmpty) // 计数不等于确认入词典。
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await reopened.correctionCandidate(for: "Claude") == expected)
        let other = try await reopened.recordCorrection(event("DC", "DeepSeek"))
        #expect(other.candidate.count == 1)
        #expect(try await reopened.correctionCandidate(for: "Claude")?.count == 3)
        print("T20：重新打开数据库，Claude 仍为 3 次；DeepSeek 单独为 1 次。")
        #expect(try await reopened.list().isEmpty)
        try await reopened.close()
    }

    @Test("同一事件重试和重开后不重复计数，新的独立纠正可以累计")
    func deduplication() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url), original = event()
        let first = try await store.recordCorrection(original)
        #expect(first.recorded && first.candidate.count == 1)
        #expect(try await store.recordCorrection(original) == CorrectionCountResult(candidate: first.candidate, recorded: false))
        _ = try await store.recordCorrection(event())
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        let repeated = try await reopened.recordCorrection(original)
        #expect(!repeated.recorded && repeated.candidate.count == 2)
        let raw = try RawCorrectionDatabase(fixture.url)
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_event") == 2)
        try await reopened.close()
    }

    @Test("同一编号改成另一条内容或另一个会话时拒绝，不串词或覆盖原事件")
    func conflictingEvent() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url), original = event()
        let first = try await store.recordCorrection(original)
        for conflict in [
            event("Cloude", id: original.id, session: original.sessionID),
            event("Cloud", "DeepSeek", id: original.id, session: original.sessionID),
            event(id: original.id)
        ] {
            await #expect(throws: CorrectionFailure.conflictingEvent) { try await store.recordCorrection(conflict) }
        }
        #expect(try await store.correctionCandidate(for: "Claude") == first.candidate)
        #expect(try await store.correctionCandidate(for: "DeepSeek") == nil)
        try await store.close()
    }

    @Test("空白、控制字符和没有实际变化不计数")
    func invalidAndUnchanged() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for invalid in ["", " \n\t", "Clau\0de", "Clau\nde", "Clau\tde", "Clau\u{7f}de"] {
            await #expect(throws: VocabularyFailure.invalidText) { try await store.recordCorrection(event(invalid)) }
            await #expect(throws: VocabularyFailure.invalidText) { try await store.recordCorrection(event("Cloud", invalid)) }
        }
        for same in [event("Claude", " Claude "), event("Caf\u{e9}", "Cafe\u{301}")] {
            await #expect(throws: CorrectionFailure.unchanged) { try await store.recordCorrection(same) }
        }
        let raw = try RawCorrectionDatabase(fixture.url)
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_candidate") == 0)
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_event") == 0)
        try await store.close()
    }

    @Test("沿用词典等价 Unicode 和首尾空白规则，保留大小写与内部空格，原样绑定特殊文字")
    func textIdentityAndBinding() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let original = event("coffee", "Caf\u{e9}")
        _ = try await store.recordCorrection(original)
        let repeatEquivalent = event(" coffee ", "Cafe\u{301}", id: original.id, session: original.sessionID)
        #expect(try await !store.recordCorrection(repeatEquivalent).recorded)
        #expect(try await store.recordCorrection(event("Cafe", " Cafe\u{301} ")).candidate.count == 2)
        _ = try await store.recordCorrection(event("Cloud", "Claude"))
        #expect(try await store.recordCorrection(event("Cloud", "claude")).candidate.count == 1)
        _ = try await store.recordCorrection(event("DC", "DeepSeek harness"))
        #expect(try await store.recordCorrection(event("DC", "DeepSeek  harness")).candidate.count == 1)
        let text = "O'Reilly 中文 👩‍💻'); DROP TABLE correction_candidate; --"
        #expect(try await store.recordCorrection(event("错词", text)).candidate.text == text)
        #expect(try await store.correctionCandidate(for: "Claude")?.count == 1)
        try await store.close()
    }

    @Test("两个连接同时写独立事件不漏计，多次递送同一事件只计一次")
    func concurrentWriters() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let first = try VocabularyStore(databaseURL: fixture.url), second = try VocabularyStore(databaseURL: fixture.url)
        let shared = event()
        let recorded = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<40 {
                let store = index.isMultiple(of: 2) ? first : second
                let correction = index < 20 ? shared : event("Cloude")
                group.addTask { try await store.recordCorrection(correction).recorded ? 1 : 0 }
            }
            var count = 0
            for try await value in group { count += value }
            return count
        }
        #expect(recorded == 21)
        #expect(try await first.correctionCandidate(for: "Claude")?.count == 21)
        #expect(try await second.correctionCandidate(for: "Claude")?.count == 21)
        let raw = try RawCorrectionDatabase(fixture.url)
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_event") == 21)
        try await first.close(); try await second.close()
    }

    @Test("事件写入失败时回滚候选新增或加一，重试只登记一次")
    func atomicRollback() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let first = try await store.recordCorrection(event())
        let raw = try RawCorrectionDatabase(fixture.url)
        try raw.execute("CREATE TRIGGER fail_event BEFORE INSERT ON correction_event BEGIN SELECT RAISE(ABORT, 'test failure'); END;")
        let pending = event("Cloude"), newWord = event("DC", "DeepSeek")
        for input in [pending, newWord] {
            await #expect(throws: VocabularyFailure.self) { try await store.recordCorrection(input) }
        }
        #expect(try await store.correctionCandidate(for: "Claude") == first.candidate)
        #expect(try await store.correctionCandidate(for: "DeepSeek") == nil)
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_event") == 1)
        try raw.execute("DROP TRIGGER fail_event")
        #expect(try await store.recordCorrection(pending).candidate.count == 2)
        #expect(try await store.recordCorrection(newWord).candidate.count == 1)
        try await store.close()
    }

    @Test("v1 升级到当前版本保留活动和已删除词条及来源，重新打开不会重复迁移")
    func migrationPreservesVocabulary() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let raw = try RawCorrectionDatabase(fixture.url)
        try raw.createV1()
        let store = try VocabularyStore(databaseURL: fixture.url)
        let words = try await store.list()
        #expect(words.map(\.text) == ["Claude", "DeepSeek"])
        #expect(words.map(\.source) == [.manual, .automatic])
        #expect(words[0].id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(words[0].createdAt == Date(timeIntervalSince1970: 100) && words[0].updatedAt == Date(timeIntervalSince1970: 101))
        #expect(try raw.integer("PRAGMA user_version") == 4)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term WHERE deleted_at = 103") == 1)
        _ = try await store.recordCorrection(event())
        await #expect(throws: VocabularyFailure.duplicate) { try await store.add(text: "Claude", source: .manual) }
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await reopened.list() == words)
        #expect(try await reopened.correctionCandidate(for: "Claude")?.count == 1)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term") == 3)
        try await reopened.close()
    }

    @Test("升级途中失败不留下半套表或升级版本，不删除原词典")
    func failedMigrationRollsBack() throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let raw = try RawCorrectionDatabase(fixture.url)
        try raw.createV1()
        try raw.execute("CREATE TABLE correction_event (unexpected TEXT)")
        #expect(throws: VocabularyFailure.self) { try VocabularyStore(databaseURL: fixture.url) }
        #expect(try raw.integer("PRAGMA user_version") == 1)
        #expect(try raw.integer("SELECT COUNT(*) FROM sqlite_master WHERE name = 'correction_candidate'") == 0)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term") == 3)
    }

    @Test("关闭或写锁占用时明确失败，释放后可重试且不会偷加次数")
    func closedAndLocked() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url), original = event()
        let first = try await store.recordCorrection(original)
        let raw = try RawCorrectionDatabase(fixture.url), pending = event()
        try raw.execute("BEGIN IMMEDIATE")
        await #expect(throws: VocabularyFailure.sqlite(SQLITE_BUSY)) { try await store.recordCorrection(pending) }
        try raw.execute("ROLLBACK")
        #expect(try await store.correctionCandidate(for: "Claude") == first.candidate)
        #expect(try await store.recordCorrection(pending).candidate.count == 2)
        try await store.close()
        await #expect(throws: VocabularyFailure.closed) { try await store.recordCorrection(event()) }
        await #expect(throws: VocabularyFailure.closed) { try await store.correctionCandidate(for: "Claude") }
    }

    @Test("计数上限不溢出，损坏计数明确失败且不改写")
    func overflowAndCorruption() async throws {
        let fixture = CorrectionFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url), original = event()
        _ = try await store.recordCorrection(original)
        let raw = try RawCorrectionDatabase(fixture.url)
        try raw.execute("UPDATE correction_candidate SET count = 9223372036854775807")
        await #expect(throws: CorrectionFailure.countOverflow) { try await store.recordCorrection(event()) }
        #expect(try await store.correctionCandidate(for: "Claude")?.count == Int64.max)
        #expect(try await !store.recordCorrection(original).recorded)
        try raw.execute("PRAGMA ignore_check_constraints = ON; UPDATE correction_candidate SET count = -1;")
        await #expect(throws: VocabularyFailure.invalidData) { try await store.correctionCandidate(for: "Claude") }
        await #expect(throws: VocabularyFailure.invalidData) { try await store.recordCorrection(event()) }
        #expect(try raw.integer("SELECT COUNT(*) FROM correction_event") == 1)
        #expect(try raw.integer("SELECT count FROM correction_candidate") == -1)
        try await store.close()
    }
}
