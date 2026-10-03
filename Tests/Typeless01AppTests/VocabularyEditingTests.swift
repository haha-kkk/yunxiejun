import Foundation
import Testing
@testable import Typeless01App

private struct EditingFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T18-\(UUID().uuidString)")
    var url: URL { directory.appendingPathComponent("vocabulary.sqlite3") }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("T18 词条编辑与撤销：真实 SQLite")
struct VocabularyEditingStoreTests {
    @Test("添加、编辑、删除、撤销删除并重开数据库，编号和来源保留")
    func lifecycleAndReopen() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let added = try await store.edit(.add("  Claude  "))
        let original = try #require(added.term)
        #expect(original.text == "Claude" && original.source == .manual)
        let edited = try await store.edit(.update(original, "Claude App"))
        let updated = try #require(edited.term)
        #expect(updated.id == original.id && updated.createdAt == original.createdAt)
        let deleted = try await store.edit(.delete(updated))
        #expect(deleted.term == nil)
        #expect(try await store.list().isEmpty)
        let restored = try await store.edit(.undo(try #require(deleted.undo)))
        let term = try #require(restored.term)
        #expect(term.text == "Claude App" && term.id == original.id && term.source == .manual)
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await reopened.list() == [term])
        try await reopened.close()
        print("T18：新增 Claude → 编辑 Claude App → 删除 → 撤销恢复；重开后词条和手动来源保留。")
    }

    @Test("撤销编辑保留自动来源，撤销添加移除新词，不能重复撤销")
    func undoKinds() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let automatic = try await store.add(text: "DeepSeek", source: .automatic)
        let edited = try await store.edit(.update(automatic, "DeepSeek harness"))
        let undo = try #require(edited.undo)
        let restored = try #require(try await store.edit(.undo(undo)).term)
        #expect(restored.text == automatic.text && restored.source == .automatic && restored.id == automatic.id)
        await #expect(throws: VocabularyFailure.changedSinceEditing) { try await store.edit(.undo(undo)) }
        let added = try await store.edit(.add("Claude"))
        let addUndo = try #require(added.undo)
        _ = try await store.edit(.undo(addUndo))
        #expect(try await store.list() == [restored])
        await #expect(throws: VocabularyFailure.changedSinceEditing) { try await store.edit(.undo(addUndo)) }
        try await store.close()
    }

    @Test("重复和非法词条不写入；撤销遇到同名词不覆盖，事务失败后可继续")
    func validationAndUndoCollision() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let original = try #require(try await store.edit(.add("Claude")).term)
        for bad in ["", " \n\t ", "Clau\nde", "Clau\0de"] {
            await #expect(throws: VocabularyFailure.invalidText) { try await store.edit(.add(bad)) }
            await #expect(throws: VocabularyFailure.invalidText) { try await store.edit(.update(original, bad)) }
        }
        await #expect(throws: VocabularyFailure.duplicate) { try await store.edit(.add("Claude")) }
        let deleted = try await store.edit(.delete(original))
        let undo = try #require(deleted.undo)
        let other = try await store.add(text: "Claude", source: .automatic)
        await #expect(throws: VocabularyFailure.duplicate) { try await store.edit(.undo(undo)) }
        #expect(try await store.list() == [other])
        _ = try await store.delete(id: other.id)
        let restored = try #require(try await store.edit(.undo(undo)).term)
        #expect(restored.id == original.id && restored.source == .manual)
        let second = try await store.add(text: "DeepSeek", source: .manual)
        await #expect(throws: VocabularyFailure.duplicate) { try await store.edit(.update(restored, second.text)) }
        #expect(try await store.term(id: restored.id) == restored)
        try await store.close()
    }

    @Test("另一个连接改过的词条不能被旧编辑、旧删除或旧撤销覆盖")
    func staleVersion() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let first = try VocabularyStore(databaseURL: fixture.url)
        let second = try VocabularyStore(databaseURL: fixture.url)
        let added = try await first.edit(.add("Claude"))
        let original = try #require(added.term)
        let changed = try await second.update(id: original.id, text: "Claude App")
        await #expect(throws: VocabularyFailure.changedSinceEditing) { try await first.edit(.update(original, "Old")) }
        await #expect(throws: VocabularyFailure.changedSinceEditing) { try await first.edit(.delete(original)) }
        let undo = try #require(added.undo)
        await #expect(throws: VocabularyFailure.changedSinceEditing) { try await first.edit(.undo(undo)) }
        #expect(try await first.list() == [changed])
        try await first.close(); try await second.close()
    }

    @Test("没有改动的保存不生成新撤销凭据")
    func unchangedEdit() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let original = try #require(try await store.edit(.add("Claude")).term)
        let result = try await store.edit(.update(original, " Claude "))
        #expect(result.term == original && result.undo == nil)
        try await store.close()
    }

    @Test("连续写入后返回版本与 SQLite 读回完全一致，避免时间精度误报冲突")
    func timestampRoundTrip() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for index in 0..<100 {
            let added = try #require(try await store.edit(.add("词条 \(index)")).term)
            #expect(try await store.term(id: added.id) == added)
            let edited = try #require(try await store.edit(.update(added, "新词条 \(index)")).term)
            #expect(try await store.term(id: added.id) == edited)
        }
        try await store.close()
    }
}

private actor DelayedVocabularyWriter: VocabularyEditing {
    private(set) var calls = 0
    private var pending: CheckedContinuation<VocabularyEditResult, Error>?
    func list() async throws -> [VocabularyTerm] { [] }
    func edit(_ edit: VocabularyEdit) async throws -> VocabularyEditResult {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: VocabularyEditResult) { pending?.resume(returning: result); pending = nil }
    func fail() { pending?.resume(throwing: NSError(domain: "private internal error", code: 1)); pending = nil }
}

@Suite("T18 词典页面操作状态")
@MainActor
struct VocabularyEditingControllerTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待词典编辑状态超时")
        throw CancellationError()
    }

    private func load(_ controller: VocabularyListController) async throws {
        controller.reload()
        try await waitUntil { !controller.isLoading }
        #expect(controller.state == .loaded)
    }

    @Test("页面增改删撤销和重新打开：真实生产读取器，不把筛选隐藏误当成丢数据")
    func pageLifecycle() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let controller = VocabularyListController(reader: LocalVocabularyReader(databaseURL: fixture.url))
        try await load(controller)
        controller.filter = .automatic; controller.query = "其他词"
        controller.beginAdding(); controller.draftText = "Claude"; controller.saveEditor()
        try await waitUntil { !controller.isSaving }
        let original = try #require(controller.terms.first)
        #expect(!controller.isEditorPresented && controller.visibleTerms == [original])
        #expect(controller.filter == .all && controller.query.isEmpty && original.source == .manual)
        controller.beginEditing(original); controller.draftText = "Claude App"; controller.saveEditor()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.first?.text == "Claude App")
        controller.undoLastEdit()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.first?.text == "Claude" && controller.undo == nil)
        controller.beginEditing(try #require(controller.terms.first)); controller.deleteEditingTerm()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.isEmpty && controller.undo?.title == "撤销删除")
        controller.undoLastEdit()
        try await waitUntil { !controller.isSaving }
        let restored = try #require(controller.terms.first)
        #expect(restored.id == original.id && restored.text == "Claude")
        let reopened = VocabularyListController(reader: LocalVocabularyReader(databaseURL: fixture.url))
        try await load(reopened)
        #expect(reopened.terms == [restored] && reopened.undo == nil)
    }

    @Test("取消草稿不写入；空白不提交；重复保存保留输入和上次撤销")
    func rejectedDraftAndRetry() async throws {
        let fixture = EditingFixture(); defer { fixture.clean() }
        let controller = VocabularyListController(reader: LocalVocabularyReader(databaseURL: fixture.url))
        try await load(controller)
        controller.beginAdding(); controller.draftText = "放弃"; controller.dismissEditor()
        #expect(controller.terms.isEmpty && controller.draftText.isEmpty)
        controller.beginAdding(); controller.draftText = "   "; controller.saveEditor()
        #expect(!controller.isSaving && !controller.canSave)
        controller.draftText = "Claude"; controller.saveEditor()
        try await waitUntil { !controller.isSaving }
        let priorUndo = controller.undo
        controller.beginAdding(); controller.draftText = "Claude"; controller.saveEditor()
        try await waitUntil { !controller.isSaving }
        #expect(controller.isEditorPresented && controller.draftText == "Claude")
        #expect(controller.editError == VocabularyFailure.duplicate.message && controller.undo == priorUndo)
        controller.draftText = "DeepSeek"; controller.saveEditor()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.count == 2 && !controller.isEditorPresented && controller.editError == nil)
        controller.undoLastEdit()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.map(\.text) == ["Claude"] && controller.undo == nil)
    }

    @Test("重复保存只发一次写入，保存中关编辑器或刷新不会丢失事务结果")
    func duplicateSave() async throws {
        let writer = DelayedVocabularyWriter()
        let controller = VocabularyListController(reader: writer)
        try await load(controller)
        controller.beginAdding(); controller.draftText = "Claude"
        controller.saveEditor(); controller.saveEditor(); controller.dismissEditor(); controller.reload()
        try await waitUntil { await writer.calls == 1 }
        #expect(controller.isSaving && controller.isEditorPresented && !controller.isLoading)
        let now = Date()
        let term = VocabularyTerm(id: UUID(), text: "Claude", source: .manual, createdAt: now, updatedAt: now)
        await writer.finish(VocabularyEditResult(affectedID: term.id, term: term, undo: VocabularyUndo(before: nil, after: term, deleted: false)))
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms == [term] && !controller.isEditorPresented && controller.undo != nil)
        #expect(await writer.calls == 1)
    }

    @Test("未知写入错误不泄漏详情、不伪造词条，用户可取消或重试")
    func failureState() async throws {
        let writer = DelayedVocabularyWriter()
        let controller = VocabularyListController(reader: writer)
        try await load(controller)
        controller.beginAdding(); controller.draftText = "Claude"; controller.saveEditor()
        try await waitUntil { await writer.calls == 1 }
        await writer.fail()
        try await waitUntil { !controller.isSaving }
        #expect(controller.terms.isEmpty && controller.undo == nil && controller.isEditorPresented)
        #expect(controller.editError == "词条操作失败，请重试。" && controller.draftText == "Claude")
        controller.dismissEditor()
        #expect(controller.editError == nil && controller.draftText.isEmpty)
    }
}
