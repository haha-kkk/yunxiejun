import CSQLite
import Foundation
import Testing
@testable import Typeless01App

private struct VocabularyFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("nested/vocabulary.sqlite3") }
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T16-\(UUID().uuidString)", isDirectory: true)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

private final class RawVocabularyDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        let code = sqlite3_open(url.path, &handle)
        guard code == SQLITE_OK else { if let handle { sqlite3_close(handle) }; handle = nil; throw VocabularyFailure.sqlite(code) }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw VocabularyFailure.sqlite(code) }
    }
    func integer(_ sql: String) throws -> Int {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &row, nil) == SQLITE_OK else { throw VocabularyFailure.invalidData }
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw VocabularyFailure.invalidData }
        return Int(sqlite3_column_int(row, 0))
    }
}

@Suite("T16 本地词典（真实隔离 SQLite 文件，不调用 API）")
struct VocabularyStoreTests {
    @Test("新增、读回、修改、删除和重新打开后持久保留")
    func crudAndReopen() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let first = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await first.list().isEmpty)
        let claude = try await first.add(text: "Claude", source: .manual)
        let deepseek = try await first.add(text: "DeepSeek", source: .automatic)
        #expect(try await first.term(id: claude.id) == claude)
        print("T16 真实 SQLite：新增 Claude（手动）、DeepSeek（自动）。")
        try await first.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await reopened.term(id: claude.id) == claude)
        #expect(try await reopened.term(id: deepseek.id) == deepseek)
        print("重新打开连接：两个词条及来源均保留。")
        let updated = try await reopened.update(id: claude.id, text: "Claude App")
        #expect(updated.id == claude.id && updated.source == .manual)
        #expect(updated.createdAt == claude.createdAt && updated.updatedAt >= claude.updatedAt)
        try await reopened.close()
        let edited = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await edited.term(id: claude.id) == updated)
        print("修改并重新打开：Claude App（手动），编号不变。")
        #expect(try await edited.delete(id: claude.id) == updated)
        try await edited.close()
        let deleted = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await deleted.term(id: claude.id) == nil)
        #expect(try await deleted.list() == [deepseek])
        try await deleted.close()
        print("删除并重新打开：Claude App 不再显示，DeepSeek（自动）仍在。")
    }

    @Test("空白及内嵌控制字符不能落库，失败不改旧词条")
    func invalidInputs() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let existing = try await store.add(text: "Claude", source: .manual)
        for text in ["", " \n\t", "\u{3000}", "Clau\0de", "Clau\nde", "Clau\tde", "Clau\u{7f}de"] {
            await #expect(throws: VocabularyFailure.invalidText) { try await store.add(text: text, source: .automatic) }
            await #expect(throws: VocabularyFailure.invalidText) { try await store.update(id: existing.id, text: text) }
        }
        #expect(try await store.list() == [existing])
        try await store.close()
    }

    @Test("去首尾空白和等价 Unicode 去重，保留大小写及内部空格")
    func textIdentity() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let claude = try await store.add(text: "  Claude \n", source: .manual)
        #expect(claude.text == "Claude")
        await #expect(throws: VocabularyFailure.duplicate) { try await store.add(text: "Claude", source: .automatic) }
        _ = try await store.add(text: "claude", source: .manual)
        _ = try await store.add(text: "Caf\u{e9}", source: .manual)
        await #expect(throws: VocabularyFailure.duplicate) { try await store.add(text: "Cafe\u{301}", source: .manual) }
        let phrase = try await store.add(text: "DeepSeek  harness", source: .automatic)
        #expect(phrase.text == "DeepSeek  harness")
        #expect(try await store.list().count == 4)
        try await store.close()
    }

    @Test("修改成已存在词条会回滚，随后仍能正常写入")
    func duplicateUpdateRollsBack() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let first = try await store.add(text: "Claude", source: .automatic)
        let second = try await store.add(text: "DeepSeek", source: .manual)
        await #expect(throws: VocabularyFailure.duplicate) { try await store.update(id: first.id, text: second.text) }
        #expect(try await store.term(id: first.id) == first)
        #expect(try await store.term(id: second.id) == second)
        let edited = try await store.update(id: first.id, text: "Claude App")
        #expect(edited.source == .automatic && edited.createdAt == first.createdAt)
        try await store.close()
    }

    @Test("不存在或已删除的编号不能误改其他词条")
    func missingIdentifiers() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let term = try await store.add(text: "Claude", source: .manual)
        #expect(try await store.term(id: UUID()) == nil)
        await #expect(throws: VocabularyFailure.notFound) { try await store.update(id: UUID(), text: "DeepSeek") }
        await #expect(throws: VocabularyFailure.notFound) { try await store.delete(id: UUID()) }
        #expect(try await store.list() == [term])
        try await store.delete(id: term.id)
        await #expect(throws: VocabularyFailure.notFound) { try await store.delete(id: term.id) }
        await #expect(throws: VocabularyFailure.notFound) { try await store.update(id: term.id, text: "Claude App") }
        try await store.close()
    }

    @Test("单引号、中文和 emoji 按原词保存，文本不能变成 SQL")
    func boundText() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let text = "O'Reilly 中文 👩‍💻'); DROP TABLE vocabulary_term; --"
        let term = try await store.add(text: text, source: .manual)
        #expect(try await store.term(id: term.id)?.text == text)
        let other = try await store.add(text: "Claude", source: .manual)
        #expect(try await store.list().count == 2)
        #expect(try await store.term(id: other.id) == other)
        try await store.close()
    }

    @Test("删除不物理抹去原行，同名重新添加获得新编号")
    func softDelete() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let original = try await store.add(text: "Claude", source: .automatic)
        try await store.delete(id: original.id)
        let replacement = try await store.add(text: "Claude", source: .manual)
        #expect(original.id != replacement.id)
        #expect(try await store.list() == [replacement])
        try await store.close()
        let raw = try RawVocabularyDatabase(fixture.url)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term") == 2)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term WHERE deleted_at IS NOT NULL") == 1)
    }

    @Test("关闭后明确报错，重复关闭安全，新连接仍能读取")
    func closedConnection() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let term = try await store.add(text: "Claude", source: .manual)
        try await store.close(); try await store.close()
        await #expect(throws: VocabularyFailure.closed) { try await store.list() }
        await #expect(throws: VocabularyFailure.closed) { try await store.term(id: term.id) }
        await #expect(throws: VocabularyFailure.closed) { try await store.add(text: "DeepSeek", source: .manual) }
        let other = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await other.list() == [term])
        try await other.close()
    }

    @Test("新版数据库不能被旧程序重建或降级")
    func futureSchema() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        _ = try await store.add(text: "Claude", source: .manual)
        try await store.close()
        let raw = try RawVocabularyDatabase(fixture.url)
        try raw.execute("PRAGMA user_version = 99")
        #expect(throws: VocabularyFailure.newerSchema(99)) { try VocabularyStore(databaseURL: fixture.url) }
        #expect(try raw.integer("PRAGMA user_version") == 99)
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term") == 1)
    }

    @Test("其他应用的库与损坏文件均拒绝，不自动覆盖")
    func foreignAndCorruptFiles() throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try RawVocabularyDatabase(fixture.url)
        try raw.execute("CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('keep');")
        #expect(throws: VocabularyFailure.incompatibleDatabase) { try VocabularyStore(databaseURL: fixture.url) }
        #expect(try raw.integer("SELECT COUNT(*) FROM unrelated") == 1)
        #expect(try raw.integer("PRAGMA user_version") == 0)
        let corrupt = fixture.directory.appendingPathComponent("corrupt.sqlite3")
        let bytes = Data("This is not a SQLite database".utf8)
        try bytes.write(to: corrupt)
        #expect(throws: VocabularyFailure.self) { try VocabularyStore(databaseURL: corrupt) }
        #expect(try Data(contentsOf: corrupt) == bytes)
    }

    @Test("两个连接并发新增同一个词也只能成功一次")
    func concurrentDuplicate() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let first = try VocabularyStore(databaseURL: fixture.url)
        let second = try VocabularyStore(databaseURL: fixture.url)
        let successes = await withTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    do { try await store.add(text: "Claude", source: .manual); return 1 }
                    catch VocabularyFailure.duplicate { return 0 }
                    catch { Issue.record("并发写入出现非重复错误：\(error)"); return 0 }
                }
            }
            var result = 0
            for await count in group { result += count }
            return result
        }
        #expect(successes == 1)
        #expect(try await first.list().count == 1)
        #expect(try await second.list().count == 1)
        try await first.close(); try await second.close()
    }

    @Test("写锁超时明确失败，释放锁后可继续写入且原词未改")
    func busyDatabase() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let term = try await store.add(text: "Claude", source: .manual)
        let raw = try RawVocabularyDatabase(fixture.url)
        try raw.execute("BEGIN IMMEDIATE")
        await #expect(throws: VocabularyFailure.sqlite(SQLITE_BUSY)) { try await store.update(id: term.id, text: "Claude App") }
        try raw.execute("ROLLBACK")
        #expect(try await store.term(id: term.id) == term)
        #expect(try await store.update(id: term.id, text: "Claude App").text == "Claude App")
        try await store.close()
    }

    @Test("不支持的路径和无法创建的目录返回明确错误")
    func invalidLocation() throws {
        #expect(throws: VocabularyFailure.invalidLocation) { try VocabularyStore(databaseURL: URL(string: "https://example.com/dictionary.db")!) }
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let parentFile = fixture.directory.appendingPathComponent("file")
        try Data("keep".utf8).write(to: parentFile)
        #expect(throws: VocabularyFailure.storageUnavailable) {
            try VocabularyStore(databaseURL: parentFile.appendingPathComponent("db.sqlite3"))
        }
        #expect(try Data(contentsOf: parentFile) == Data("keep".utf8))
        #expect(try VocabularyStore.defaultDatabaseURL().lastPathComponent == "vocabulary.sqlite3")
    }

    @Test("已损坏的词条读取报错，不静默遗漏或伪造来源")
    func invalidRow() async throws {
        let fixture = VocabularyFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        _ = try await store.add(text: "Claude", source: .manual)
        let raw = try RawVocabularyDatabase(fixture.url)
        try raw.execute("PRAGMA ignore_check_constraints = ON; UPDATE vocabulary_term SET source = 'unknown';")
        await #expect(throws: VocabularyFailure.invalidData) { try await store.list() }
        #expect(try raw.integer("SELECT COUNT(*) FROM vocabulary_term") == 1)
        try await store.close()
    }
}
