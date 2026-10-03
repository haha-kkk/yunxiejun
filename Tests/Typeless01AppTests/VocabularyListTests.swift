import Foundation
import Testing
@testable import Typeless01App

private func listTerm(_ text: String, source: VocabularySource = .manual) -> VocabularyTerm {
    VocabularyTerm(id: UUID(), text: text, source: source, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
}

private actor WaitingVocabularyReader: VocabularyListing {
    private var pending: [CheckedContinuation<[VocabularyTerm], Error>] = []
    private(set) var calls = 0
    func list() async throws -> [VocabularyTerm] {
        calls += 1
        // 故意忽略取消，让页面控制器负责拒绝已关闭或已过期的结果。
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func succeed(_ terms: [VocabularyTerm]) { pending.removeFirst().resume(returning: terms) }
    func fail(_ error: Error) { pending.removeFirst().resume(throwing: error) }
}

@Suite("T17 词典列表、分类、搜索与加载状态")
@MainActor
struct VocabularyListTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待词典测试状态超时")
        throw CancellationError()
    }

    @Test("真实 SQLite 词条经页面读取器加载，分类和搜索组合生效")
    func persistedFiltersAndSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T17-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.sqlite3")
        let store = try VocabularyStore(databaseURL: url)
        let claude = try await store.add(text: "Claude", source: .automatic)
        let claudeApp = try await store.add(text: "Claude App", source: .manual)
        let deepseek = try await store.add(text: "DeepSeek", source: .manual)
        let deleted = try await store.add(text: "Deleted Claude", source: .manual)
        try await store.delete(id: deleted.id)
        try await store.close()

        let controller = VocabularyListController(reader: LocalVocabularyReader(databaseURL: url))
        controller.reload()
        try await waitUntil { !controller.isLoading }
        #expect(controller.state == .loaded)
        #expect(Set(controller.visibleTerms.map(\.id)) == [claude.id, claudeApp.id, deepseek.id])
        controller.filter = .automatic
        #expect(controller.visibleTerms == [claude])
        controller.filter = .manual
        #expect(Set(controller.visibleTerms.map(\.id)) == [claudeApp.id, deepseek.id])
        controller.filter = .all
        controller.query = "  cLaUdE \n"
        #expect(Set(controller.visibleTerms.map(\.id)) == [claude.id, claudeApp.id])
        controller.filter = .automatic
        #expect(controller.visibleTerms == [claude])
        controller.filter = .manual
        #expect(controller.visibleTerms == [claudeApp])
        controller.query = "not-found"
        #expect(controller.visibleTerms.isEmpty)
        #expect(controller.emptyMessage.contains("没有匹配"))
        controller.query = ""
        #expect(controller.visibleTerms.count == 2)
        print("T17 真实临时词库：所有 3 个；自动 1 个；手动 2 个。")
        print("搜索 cLaUdE：所有 2 个；自动 1 个；手动 1 个；无匹配时显示空结果。")
    }

    @Test("空词典、分类无词与搜索无匹配的提示不同")
    func emptyStates() async throws {
        let reader = WaitingVocabularyReader()
        let controller = VocabularyListController(reader: reader)
        controller.reload()
        try await waitUntil { await reader.calls == 1 }
        await reader.succeed([])
        try await waitUntil { controller.state == .loaded }
        #expect(controller.emptyMessage == "词典还是空的。")
        controller.reload()
        try await waitUntil { await reader.calls == 2 }
        await reader.succeed([listTerm("Claude")])
        try await waitUntil { controller.state == .loaded }
        controller.filter = .automatic
        #expect(controller.visibleTerms.isEmpty)
        #expect(controller.emptyMessage == "还没有自动添加的词条。")
        controller.query = "不存在"
        #expect(controller.emptyMessage.contains("没有匹配"))
        controller.filter = .all
        controller.query = " \n "
        #expect(controller.visibleTerms.count == 1)
    }

    @Test("中文、组合字符与特殊符号按名称搜索，不当成 SQL 或通配符")
    func unicodeAndLiteralSearch() async throws {
        let reader = WaitingVocabularyReader()
        let controller = VocabularyListController(reader: reader)
        let terms = [listTerm("Café"), listTerm("中文 👩‍💻"), listTerm("100%_match"), listTerm("O'Reilly")]
        controller.reload()
        try await waitUntil { await reader.calls == 1 }
        await reader.succeed(terms)
        try await waitUntil { controller.state == .loaded }
        for (query, index) in [("Cafe\u{301}", 0), ("中文", 1), ("👩‍💻", 1), ("%_", 2), ("'", 3)] {
            controller.query = query
            #expect(controller.visibleTerms == [terms[index]])
        }
    }

    @Test("重复刷新仅加载一次，加载期间修改查询应用于新结果")
    func duplicateLoadAndCurrentQuery() async throws {
        let reader = WaitingVocabularyReader()
        let controller = VocabularyListController(reader: reader)
        controller.reload(); controller.reload()
        try await waitUntil { await reader.calls == 1 }
        controller.filter = .automatic; controller.query = "Claude"
        let expected = listTerm("Claude", source: .automatic)
        await reader.succeed([expected, listTerm("Claude"), listTerm("DeepSeek", source: .automatic)])
        try await waitUntil { controller.state == .loaded }
        #expect(await reader.calls == 1)
        #expect(controller.visibleTerms == [expected])
    }

    @Test("立即关闭不开始读取，再打开可重新加载")
    func immediateClose() async throws {
        let reader = WaitingVocabularyReader()
        let controller = VocabularyListController(reader: reader)
        controller.reload(); controller.cancelLoading()
        for _ in 0..<20 { await Task.yield() }
        #expect(await reader.calls == 0)
        #expect(controller.state == .idle)
        controller.reload()
        try await waitUntil { await reader.calls == 1 }
        await reader.succeed([])
        try await waitUntil { controller.state == .loaded }
    }

    @Test("关窗重开后旧成功与旧错误不能覆盖新列表")
    func staleLoads() async throws {
        for failOld in [false, true] {
            let reader = WaitingVocabularyReader()
            let controller = VocabularyListController(reader: reader)
            controller.reload()
            try await waitUntil { await reader.calls == 1 }
            controller.cancelLoading(); controller.reload()
            try await waitUntil { await reader.calls == 2 }
            if failOld { await reader.fail(VocabularyFailure.invalidData) }
            else { await reader.succeed([listTerm("old")]) }
            for _ in 0..<20 { await Task.yield() }
            #expect(controller.state == .loading && controller.terms.isEmpty)
            let current = listTerm("current")
            await reader.succeed([current])
            try await waitUntil { controller.state == .loaded }
            #expect(controller.terms == [current])
        }
    }

    @Test("读库失败不伪装为空词典，错误后可重试")
    func failureAndRetry() async throws {
        let reader = WaitingVocabularyReader()
        let controller = VocabularyListController(reader: reader)
        controller.reload()
        try await waitUntil { await reader.calls == 1 }
        await reader.fail(VocabularyFailure.newerSchema(99))
        try await waitUntil { !controller.isLoading }
        #expect(controller.state == .failed(VocabularyFailure.newerSchema(99).message))
        controller.reload()
        try await waitUntil { await reader.calls == 2 }
        let term = listTerm("Claude")
        await reader.succeed([term])
        try await waitUntil { controller.state == .loaded }
        #expect(controller.visibleTerms == [term])
        controller.reload()
        #expect(controller.terms.isEmpty)
        try await waitUntil { await reader.calls == 3 }
        await reader.fail(NSError(domain: "sensitive internal details", code: 1))
        try await waitUntil { !controller.isLoading }
        #expect(controller.state == .failed("读取词典失败，请重试。"))
    }

    @Test("生产读取器遇到开库失败后不缓存失败状态，可在路径修复后重试")
    func readerOpenRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T17-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obstruction = directory.appendingPathComponent("parent")
        try Data("test-only obstruction".utf8).write(to: obstruction)
        let reader = LocalVocabularyReader(databaseURL: obstruction.appendingPathComponent("vocabulary.sqlite3"))
        await #expect(throws: VocabularyFailure.storageUnavailable) { try await reader.list() }
        try FileManager.default.removeItem(at: obstruction)
        #expect(try await reader.list().isEmpty)
    }
}
