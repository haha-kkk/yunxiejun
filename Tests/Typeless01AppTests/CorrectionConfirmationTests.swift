import CSQLite
import Foundation
import Testing
@testable import Typeless01App

private struct ConfirmationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-T21-\(UUID().uuidString)", isDirectory: true)
    var url: URL { directory.appendingPathComponent("vocabulary.sqlite3") }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw VocabularyFailure.invalidData }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw VocabularyFailure.invalidData }
    }
}

@Suite("T21 三次纠正确认及持久化")
struct CorrectionConfirmationTests {
    private func event(_ before: String = "Cloud", _ after: String = "Claude") -> TermCorrection {
        TermCorrection(id: UUID(), sessionID: UUID(), observedText: before, correctedText: after)
    }
    private func three(_ store: VocabularyStore, target: String = "Claude") async throws -> CorrectionCandidate {
        for before in ["Cloud", "Cloude"] { _ = try await store.recordCorrection(event(before, target)) }
        return try await store.recordCorrection(event("Cloud AI", target)).candidate
    }

    @Test("第三次才待确认，重开保留；同意后进入自动词典且可撤销")
    func acceptAndUndo() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for before in ["Cloud", "Cloude"] {
            _ = try await store.recordCorrection(event(before))
            #expect(try await store.pendingCorrections().isEmpty)
        }
        let third = try await store.recordCorrection(event("Cloud AI"))
        #expect(third.candidate.status == .pending && third.candidate.count == 3)
        #expect(try await store.list().isEmpty)
        try await store.close()
        let reopened = try VocabularyStore(databaseURL: fixture.url)
        #expect(try await reopened.pendingCorrections() == [third.candidate])
        let result = try await reopened.decideCorrection(id: third.candidate.id, accept: true)
        #expect(result.term?.text == "Claude" && result.term?.source == .automatic)
        #expect(result.candidate.status == .accepted && result.candidate.decisionCount == 3)
        #expect(try await reopened.pendingCorrections().isEmpty)
        let undo = try #require(result.undo)
        _ = try await reopened.edit(.undo(undo))
        #expect(try await reopened.list().isEmpty)
        _ = try await reopened.recordCorrection(event())
        #expect(try await reopened.pendingCorrections().isEmpty) // 用户撤销后不马上加回。
        try await reopened.close()
    }

    @Test("取消不入词典且持久保留；两种再次询问规则都不在下一次立刻重弹")
    func dismissPolicies() async throws {
        for policy in [CorrectionDismissalPolicy.afterThreeNewCorrections, .neverAskAgain] {
            let fixture = ConfirmationFixture(); defer { fixture.clean() }
            let store = try VocabularyStore(databaseURL: fixture.url)
            let candidate = try await three(store)
            _ = try await store.decideCorrection(id: candidate.id, accept: false)
            #expect(try await store.list().isEmpty)
            try await store.close()
            let reopened = try VocabularyStore(databaseURL: fixture.url)
            #expect(try await reopened.pendingCorrections().isEmpty)
            for _ in 0..<2 {
                _ = try await reopened.recordCorrection(event(), dismissalPolicy: policy)
                #expect(try await reopened.pendingCorrections().isEmpty)
            }
            let sixth = try await reopened.recordCorrection(event(), dismissalPolicy: policy)
            #expect(sixth.candidate.count == 6)
            #expect(sixth.candidate.status == (policy == .afterThreeNewCorrections ? .pending : .dismissed))
            #expect(try await reopened.list().isEmpty)
            try await reopened.close()
        }
    }

    @Test("重复或相反确认不能覆盖已处理决定；已存在的手动词保留来源")
    func duplicateDecisionsAndExistingWord() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let candidate = try await three(store)
        let original = try await store.add(text: "Claude", source: .manual)
        let result = try await store.decideCorrection(id: candidate.id, accept: true)
        #expect(result.term == original && result.undo == nil)
        for choice in [true, false] {
            await #expect(throws: CorrectionFailure.notPending) { try await store.decideCorrection(id: candidate.id, accept: choice) }
        }
        #expect(try await store.list() == [original])
        let existing = try await three(store, target: "DeepSeek")
        _ = try await store.decideCorrection(id: existing.id, accept: false)
        await #expect(throws: CorrectionFailure.notPending) { try await store.decideCorrection(id: existing.id, accept: true) }
        try await store.close()
    }

    @Test("词条写入或状态更新失败会回滚整个确认，建议仍可重试")
    func confirmationRollback() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        let candidate = try await three(store)
        try fixture.execute("CREATE TRIGGER fail_decision BEFORE UPDATE OF status ON correction_candidate BEGIN SELECT RAISE(ABORT, 'test'); END;")
        await #expect(throws: VocabularyFailure.self) { try await store.decideCorrection(id: candidate.id, accept: true) }
        #expect(try await store.list().isEmpty)
        #expect(try await store.pendingCorrections() == [candidate])
        try fixture.execute("DROP TRIGGER fail_decision")
        #expect(try await store.decideCorrection(id: candidate.id, accept: true).term?.source == .automatic)
        try await store.close()
    }

    @Test("两个连接并发确认只新增一个词条")
    func concurrentConfirmation() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let first = try VocabularyStore(databaseURL: fixture.url), second = try VocabularyStore(databaseURL: fixture.url)
        let candidate = try await three(first)
        let successes = await withTaskGroup(of: Int.self) { group in
            for store in [first, second] {
                group.addTask {
                    do { _ = try await store.decideCorrection(id: candidate.id, accept: true); return 1 }
                    catch CorrectionFailure.notPending { return 0 }
                    catch { Issue.record("确认出现意外失败：\(error)"); return 0 }
                }
            }
            var total = 0
            for await value in group { total += value }
            return total
        }
        #expect(successes == 1)
        #expect(try await first.list().count == 1)
        try await first.close(); try await second.close()
    }

    @Test("v2 升级保留计数与事件，三次候选转为待确认")
    func migrateV2() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try fixture.execute("""
            PRAGMA application_id = 0x54593031; PRAGMA user_version = 2;
            CREATE TABLE vocabulary_term (id TEXT PRIMARY KEY, canonical_text TEXT, normalized_key TEXT, source TEXT, created_at REAL, updated_at REAL, deleted_at REAL);
            CREATE UNIQUE INDEX vocabulary_active_key ON vocabulary_term(normalized_key) WHERE deleted_at IS NULL;
            CREATE TABLE correction_candidate (id TEXT PRIMARY KEY, canonical_text TEXT, normalized_key TEXT UNIQUE, count INTEGER, updated_at REAL);
            CREATE TABLE correction_event (id TEXT PRIMARY KEY, candidate_id TEXT, session_id TEXT, observed_text TEXT, corrected_text TEXT, created_at REAL);
            INSERT INTO correction_candidate VALUES ('11111111-1111-1111-1111-111111111111', 'Claude', 'Claude', 3, 100);
            INSERT INTO correction_event VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', 'Cloud', 'Claude', 100);
            """)
        let store = try VocabularyStore(databaseURL: fixture.url)
        let pending = try await store.pendingCorrections()
        #expect(pending.count == 1 && pending.first?.count == 3)
        let repeated = TermCorrection(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, observedText: "Cloud", correctedText: "Claude")
        #expect(try await !store.recordCorrection(repeated).recorded)
        try await store.close()
    }
}

@Suite("T21 稳定编辑与词语提取")
struct StableTermCorrectionTests {
    @Test("英文整词、多词错法及中英混排提取为完整词，不是单个变化字母")
    func replacement() {
        for before in ["Cloud", "Cloude", "Cloud AI"] {
            let result = TermReplacement.extract(before: "请用 \(before) 整理需求。", after: "请用 Claude 整理需求。")
            #expect(result?.0 == before && result?.1 == "Claude")
        }
        #expect(TermReplacement.extract(before: "请用Cloud整理需求。", after: "请用Claude整理需求。")?.1 == "Claude")
        #expect(TermReplacement.extract(before: "使用 DC。", after: "使用 DeepSeek。")?.1 == "DeepSeek")
        let prefix = "这是一次输入测试。"
        #expect(TermReplacement.extract(before: prefix + "我想用 Claude 写文章。",
                                        after: prefix + "我想用 云写君写文章。")?.1 == "云写君")
        #expect(TermReplacement.extract(before: prefix + "我想用 Claude 写文章。",
                                        after: prefix + "我想用云写君写文章。")?.1 == "云写君")
    }

    @Test("纯插入、删除、标点、长段落或分散多处编辑不学习")
    func rejectAmbiguousEdits() {
        for (before, after) in [
            ("", "Claude"), ("Cloud", ""), ("Cloud", "Cloud。"),
            ("Cloud test DC", "Claude test DeepSeek"), ("请用 Cloud。", "请用 Claude！"),
            ("我想用 Claude 写文章。", "我想用云写君写需求。"),
            ("a b c d", "w x y z"), (String(repeating: "a", count: 81), "Claude")
        ] { #expect(TermReplacement.extract(before: before, after: after) == nil) }
    }

    @Test("建立稳定基线后等待修改停稳，只发一次；失焦或换框不拼接")
    func stableAndScoped() throws {
        var observer = StableTermCorrection()
        let field = UUID()
        func sample(_ text: String, id: UUID? = nil, pid: Int32 = 1) -> ExternalTextSnapshot {
            ExternalTextSnapshot(targetPID: pid, fieldID: id ?? field, role: "AXTextArea", text: "请用 \(text) 整理需求。")
        }
        observer.begin()
        #expect(observer.receive(sample("Cloud"), now: 0) == nil)
        #expect(observer.receive(sample("Cloud"), now: 1) == nil)
        #expect(observer.receive(sample("Cl"), now: 1.1) == nil)
        #expect(observer.receive(sample("Clau"), now: 1.3) == nil)
        #expect(observer.receive(sample("Claude"), now: 1.5) == nil)
        #expect(observer.receive(sample("Claude"), now: 2.0) == nil)
        let emitted = observer.receive(sample("Claude"), now: 2.6)
        let correction = try #require(emitted)
        #expect(correction.observedText == "Cloud" && correction.correctedText == "Claude")
        #expect(observer.receive(sample("DeepSeek"), now: 4) == nil)
        #expect(observer.receive(sample("DeepSeek"), now: 5) == nil)
        observer.begin()
        _ = observer.receive(sample("Cloud"), now: 10); _ = observer.receive(sample("Cloud"), now: 11)
        observer.breakContinuity()
        #expect(observer.receive(sample("Claude"), now: 12) == nil)
        #expect(observer.receive(sample("Claude"), now: 13) == nil)
        #expect(observer.receive(sample("DeepSeek", id: UUID()), now: 14) == nil)
        #expect(observer.receive(sample("DC", pid: 2), now: 15) == nil)
    }
}

@Suite("T21 页面状态与真实持久层")
@MainActor
struct CorrectionLearningControllerTests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CancellationError()
    }

    @Test("稳定修改接上第三次确认；连点是的只写一次，词典可撤销")
    func controllerAccept() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for _ in 0..<2 {
            _ = try await store.recordCorrection(TermCorrection(id: UUID(), sessionID: UUID(), observedText: "Cloud", correctedText: "Claude"))
        }
        var now: TimeInterval = 0
        let probe = ExternalTextProbeController()
        let controller = CorrectionLearningController(store: store, probe: probe, dismissalPolicy: .neverAskAgain, now: { now })
        let vocabulary = VocabularyListController(reader: store)
        vocabulary.reload(); try await waitUntil { vocabulary.state == .loaded }
        controller.onAccepted = { vocabulary.receiveAutomaticAddition($0) }
        let id = UUID()
        func sample(_ text: String) -> ExternalTextSnapshot { ExternalTextSnapshot(targetPID: 1, fieldID: id, role: "AXTextArea", text: "请用 \(text) 整理需求。") }
        probe.onSample?(sample("Cloud")); now = 1; probe.onSample?(sample("Cloud"))
        now = 2; probe.onSample?(sample("Claude")); now = 3; probe.onSample?(sample("Claude"))
        try await waitUntil { !controller.isSaving && controller.pending.count == 1 }
        #expect(controller.lastCount?.count == 3)
        controller.decide(accept: true); controller.decide(accept: true)
        try await waitUntil { !controller.isSaving && controller.pending.isEmpty }
        #expect(vocabulary.terms.count == 1 && vocabulary.terms.first?.source == .automatic)
        vocabulary.undoLastEdit()
        try await waitUntil { !vocabulary.isSaving }
        #expect(try await store.list().isEmpty)
        try await store.close()
    }

    @Test("取消与确认失败可见，不伪造成功或重复加入；重试后成功")
    func controllerFailureAndCancel() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for word in ["Claude", "DeepSeek"] {
            for _ in 0..<3 { _ = try await store.recordCorrection(TermCorrection(id: UUID(), sessionID: UUID(), observedText: "错词", correctedText: word)) }
        }
        let controller = CorrectionLearningController(store: store, probe: ExternalTextProbeController(), dismissalPolicy: .neverAskAgain)
        controller.reloadPending(); try await waitUntil { !controller.isLoading }
        #expect(controller.pending.count == 2)
        controller.decide(accept: false); try await waitUntil { !controller.isSaving }
        #expect(controller.pending.count == 1)
        #expect(try await store.list().isEmpty)
        try fixture.execute("CREATE TRIGGER fail_confirm BEFORE INSERT ON vocabulary_term BEGIN SELECT RAISE(ABORT, 'test'); END;")
        controller.decide(accept: true); try await waitUntil { !controller.isSaving }
        #expect(controller.error != nil && controller.pending.count == 1)
        try fixture.execute("DROP TRIGGER fail_confirm")
        controller.decide(accept: true); try await waitUntil { !controller.isSaving }
        #expect(controller.error == nil && controller.pending.isEmpty)
        #expect(try await store.list().count == 1)
        try await store.close()
    }

    @Test("计数保存失败后可重试，同一次事件不会变成第四次")
    func retryFailedCounting() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for _ in 0..<2 { _ = try await store.recordCorrection(TermCorrection(id: UUID(), sessionID: UUID(), observedText: "Cloud", correctedText: "Claude")) }
        try fixture.execute("CREATE TRIGGER fail_event BEFORE INSERT ON correction_event BEGIN SELECT RAISE(ABORT, 'test'); END;")
        var now: TimeInterval = 0
        let probe = ExternalTextProbeController()
        let controller = CorrectionLearningController(store: store, probe: probe, dismissalPolicy: .neverAskAgain, now: { now })
        let field = UUID()
        func send(_ text: String, at time: TimeInterval) {
            now = time
            probe.onSample?(ExternalTextSnapshot(targetPID: 1, fieldID: field, role: "AXTextArea", text: text))
        }
        send("Cloud", at: 0); send("Cloud", at: 1)
        send("Claude", at: 2); send("Claude", at: 3)
        try await waitUntil { !controller.isSaving && controller.error != nil }
        #expect(controller.canRetry && controller.pending.isEmpty)
        #expect(try await store.correctionCandidate(for: "Claude")?.count == 2)
        try fixture.execute("DROP TRIGGER fail_event")
        controller.retryRecording(); controller.retryRecording()
        try await waitUntil { !controller.isSaving && !controller.canRetry }
        send("Claude", at: 4)
        #expect(controller.pending.count == 1 && controller.lastCount?.count == 3)
        #expect(try await store.correctionCandidate(for: "Claude")?.count == 3)
        try await store.close()
    }

    @Test("旧刷新延迟返回不能覆盖第三次新建议")
    func stalePendingLoad() async throws {
        let fixture = ConfirmationFixture(); defer { fixture.clean() }
        let store = try VocabularyStore(databaseURL: fixture.url)
        for _ in 0..<2 { _ = try await store.recordCorrection(TermCorrection(id: UUID(), sessionID: UUID(), observedText: "Cloud", correctedText: "Claude")) }
        let delayed = DelayedPendingStore(store: store)
        var now: TimeInterval = 0
        let probe = ExternalTextProbeController()
        let controller = CorrectionLearningController(store: delayed, probe: probe, dismissalPolicy: .neverAskAgain, now: { now })
        controller.reloadPending()
        for _ in 0..<1000 {
            if await delayed.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await delayed.isWaiting)
        let field = UUID()
        func send(_ text: String, at time: TimeInterval) {
            now = time
            probe.onSample?(ExternalTextSnapshot(targetPID: 1, fieldID: field, role: "AXTextArea", text: text))
        }
        send("Cloud", at: 0); send("Cloud", at: 1); send("Claude", at: 2); send("Claude", at: 3)
        try await waitUntil { !controller.isSaving && controller.pending.count == 1 }
        await delayed.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.pending.first?.text == "Claude")
        try await store.close()
    }
}

private actor DelayedPendingStore: CorrectionLearning {
    let store: VocabularyStore
    private var continuation: CheckedContinuation<[CorrectionCandidate], Never>?
    var isWaiting: Bool { continuation != nil }
    init(store: VocabularyStore) { self.store = store }
    func pendingCorrections() async throws -> [CorrectionCandidate] {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: []); continuation = nil }
    func recordCorrection(_ event: TermCorrection, dismissalPolicy: CorrectionDismissalPolicy) async throws -> CorrectionCountResult {
        try await store.recordCorrection(event, dismissalPolicy: dismissalPolicy)
    }
    func decideCorrection(id: UUID, accept: Bool) async throws -> CorrectionDecisionResult {
        try await store.decideCorrection(id: id, accept: accept)
    }
}
