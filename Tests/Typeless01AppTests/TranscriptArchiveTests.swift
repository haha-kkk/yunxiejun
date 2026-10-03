import CSQLite
import Foundation
import Testing
@testable import Typeless01App

actor TestArchiveStore: TranscriptArchiving {
    var records: [CompletedTranscript] = []
    var failWrites = false
    var failReads = false
    func configure(failWrites: Bool = false, failReads: Bool = false) { self.failWrites = failWrites; self.failReads = failReads }
    func saveTranscript(_ transcript: CompletedTranscript) throws {
        if failWrites { throw VocabularyFailure.storageUnavailable }
        if !records.contains(where: { $0.id == transcript.id }) { records.insert(transcript, at: 0) }
    }
    func listTranscripts(limit: Int, offset: Int) throws -> [CompletedTranscript] {
        if failReads { throw VocabularyFailure.storageUnavailable }
        return Array(records.dropFirst(offset).prefix(limit))
    }
}

private actor ArchiveTimer {
    var waits: [CheckedContinuation<Void, Never>] = []
    var durations: [Duration] = []
    func wait(_ duration: Duration) async { durations.append(duration); await withCheckedContinuation { waits.append($0) } }
    func fireFirst() { waits.removeFirst().resume() }
}

private func archiveWait(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待归档测试超时"); throw CancellationError()
}

@Suite("T25 本地完成结果归档与浮窗期限")
struct TranscriptArchiveTests {
    private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T25-\(UUID())/data.sqlite3") }
    private func entry(_ index: Int = 0) -> CompletedTranscript {
        CompletedTranscript(id: UUID(), text: "第 \(index) 条：Claude 👩🏽‍💻\n先不要发布。", createdAt: Date(timeIntervalSince1970: Double(index)))
    }
    private func raw(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw VocabularyFailure.storageUnavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VocabularyFailure.invalidData }
    }

    @Test("最终结果重开后仍在，重复编号不覆盖，分页能找回更早记录")
    func persistence() async throws {
        let url = path(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try VocabularyStore(databaseURL: url)
        var inserted: [CompletedTranscript] = []
        for index in 0..<55 {
            let item = entry(index); inserted.append(item); try await store.saveTranscript(item)
        }
        try await store.saveTranscript(inserted[0])
        let conflicting = CompletedTranscript(id: inserted[0].id, text: "不同文本", createdAt: inserted[0].createdAt)
        await #expect(throws: VocabularyFailure.invalidData) { try await store.saveTranscript(conflicting) }
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: url)
        let first = try await reopened.listTranscripts(limit: 50, offset: 0)
        let second = try await reopened.listTranscripts(limit: 50, offset: 50)
        #expect(first + second == inserted.reversed())
        #expect(try await reopened.listTranscripts(limit: 50, offset: 100).isEmpty)
        try await reopened.close()
    }

    @Test("原词典从版本三升级后保持原词条，失败迁移不重建数据库")
    func migration() async throws {
        let url = path(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try VocabularyStore(databaseURL: url)
        let term = try await store.add(text: "Claude", source: .manual)
        try await store.close()
        try raw(url, "DROP TABLE completed_transcript; PRAGMA user_version = 3;")
        let upgraded = try VocabularyStore(databaseURL: url)
        #expect(try await upgraded.list() == [term])
        try await upgraded.saveTranscript(entry())
        try await upgraded.close()
        try raw(url, "PRAGMA user_version = 3;") // 制造表名冲突，迁移必须回滚。
        #expect(throws: (any Error).self) { try VocabularyStore(databaseURL: url) }
        try raw(url, "PRAGMA user_version = 4;")
        let restored = try VocabularyStore(databaseURL: url)
        #expect(try await restored.list() == [term])
        #expect(try await restored.listTranscripts(limit: 50, offset: 0).count == 1)
        try await restored.close()
    }

    @Test("空白、NUL、非法时间和分页参数明确拒绝，关闭连接后写入失败")
    func invalidData() async throws {
        let url = path(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try VocabularyStore(databaseURL: url)
        for text in [" \n", "前\0后"] {
            await #expect(throws: VocabularyFailure.invalidData) {
                try await store.saveTranscript(CompletedTranscript(id: UUID(), text: text, createdAt: Date()))
            }
        }
        await #expect(throws: VocabularyFailure.invalidData) {
            try await store.saveTranscript(CompletedTranscript(id: UUID(), text: "正文", createdAt: Date(timeIntervalSince1970: .infinity)))
        }
        await #expect(throws: VocabularyFailure.invalidData) { try await store.listTranscripts(limit: 0, offset: 0) }
        await #expect(throws: VocabularyFailure.invalidData) { try await store.listTranscripts(limit: 50, offset: -1) }
        try await store.close()
        await #expect(throws: VocabularyFailure.closed) { try await store.saveTranscript(entry()) }
    }

    @Test("只有终态结果归档，处理中取消不存；保存失败保留并能重试")
    @MainActor func stateAndRetry() async throws {
        let store = TestArchiveStore()
        let subject = TranscriptArchiveController(store: store)
        let id = UUID(), result = try TextCleanupResult(request: TextCleanupRequest(originalText: "原文"), output: "最终文字")
        subject.receive(state: .awaitingOutput(id, text: "最终文字"), result: result)
        subject.receive(state: .cancelled(id), result: result)
        subject.receive(state: .failed(id, reason: .processingFailed), result: result)
        for _ in 0..<10 { await Task.yield() }
        #expect(await store.records.isEmpty)
        await store.configure(failWrites: true)
        subject.receive(state: .completed(id, text: "最终文字"), result: result)
        try await archiveWait { !subject.isSaving }
        #expect(subject.saveError != nil && subject.entries.isEmpty)
        await store.configure()
        subject.retrySaving()
        try await archiveWait { !subject.isSaving && !subject.isLoading }
        #expect(subject.entries.first?.text == result.cleanedText && subject.saveError == nil)
        // 新建页面控制器并重新加载，不能依靠旧控制器内存冒充持久结果。
        let reopened = TranscriptArchiveController(store: store)
        reopened.reload()
        try await archiveWait { !reopened.isLoading }
        #expect(reopened.entries == subject.entries)
    }

    @Test("列表读取失败保留记录并可刷新，打开和加载不自动复制")
    @MainActor func listingAndCopy() async throws {
        let store = TestArchiveStore()
        for index in 0..<55 { try await store.saveTranscript(entry(index)) }
        var copied: [String] = []
        let controller = TranscriptArchiveController(store: store, writeClipboard: { copied.append($0); return true })
        controller.reload(); try await archiveWait { !controller.isLoading }
        #expect(controller.entries.count == 50 && controller.hasMore && copied.isEmpty)
        controller.loadMore(); try await archiveWait { !controller.isLoading }
        #expect(controller.entries.count == 55 && !controller.hasMore)
        await store.configure(failReads: true)
        controller.reload(); try await archiveWait { !controller.isLoading }
        #expect(controller.loadError != nil && controller.entries.count == 55)
        await store.configure()
        controller.reload(); try await archiveWait { !controller.isLoading }
        #expect(controller.loadError == nil && copied.isEmpty)
        let item = try #require(controller.entries.first)
        controller.copy(item)
        #expect(copied == [item.text] && controller.copyStatus.contains("已复制"))
    }

    @Test("浮窗默认十分钟，迟到旧计时器不关闭新结果，关闭不影响归档或剪贴板")
    @MainActor func expiration() async throws {
        let timer = ArchiveTimer()
        var writes = 0
        let model = ResultOverlayModel(waitForExpiry: { await timer.wait($0) }, writeClipboard: { _ in writes += 1; return true })
        let first = UUID(), next = UUID(), result = try TextCleanupResult(request: TextCleanupRequest(originalText: "原文"), output: "最终文字")
        model.receive(state: .failed(first, reason: .outputFailed), result: result, status: "失败")
        try await archiveWait { await timer.waits.count == 1 }
        model.receive(state: .recording(next), result: nil, status: "录音中")
        model.receive(state: .failed(next, reason: .outputFailed), result: result, status: "失败")
        try await archiveWait { await timer.waits.count == 2 }
        await timer.fireFirst()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.content?.id == next)
        await timer.fireFirst()
        try await archiveWait { model.content == nil }
        model.receive(state: .failed(next, reason: .outputFailed), result: result, status: "重复通知")
        #expect(model.content == nil && writes == 0)
        #expect(await timer.durations == [.seconds(600), .seconds(600)])
    }
}
