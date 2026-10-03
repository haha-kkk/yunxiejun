import Foundation
import Testing
@testable import Typeless01App

private actor OutputLearningReader: ExternalTextReading {
    var result: ExternalTextReadResult
    var reads = 0
    init(_ result: ExternalTextReadResult) { self.result = result }
    func read(targetPID: Int32) -> ExternalTextReadResult { reads += 1; return result }
}

private func learningWait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("等待自动纠词整合超时"); throw CancellationError()
}

@Suite("I03 成功输出后的原输入框纠词整合")
@MainActor
struct OutputCorrectionIntegrationTests {
    private let target = ExternalTextTarget(id: 100, name: "测试编辑器", bundleIdentifier: "test")
    private func sample(_ text: String, field: UUID) -> ExternalTextSnapshot {
        ExternalTextSnapshot(targetPID: target.id, fieldID: field, role: "AXTextArea", text: text)
    }

    @Test("成功输出的基线无需手动启动，三轮原框改词触发确认，确认后写入共享词典")
    func threeCorrections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-I03-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VocabularyStore(databaseURL: root.appendingPathComponent("terms.sqlite3"))
        let probe = ExternalTextProbeController(trusted: { true }, foregroundPID: { 100 }, isAlive: { _ in true },
                                               duration: .seconds(2), interval: .milliseconds(5))
        var now = 0.0
        let learning = CorrectionLearningController(store: store, probe: probe, dismissalPolicy: .afterThreeNewCorrections,
            now: { now += 2; return now })
        for count in 1...3 {
            let field = UUID()
            let reader = OutputLearningReader(.readable(sample("请用 Claude 整理需求。", field: field)))
            let context = OutputCorrectionContext(target: target, baseline: sample("请用 Cloud 整理需求。", field: field), reader: reader)
            learning.startAfterOutput(context)
            try await learningWait { !probe.isRunning && !learning.isSaving && learning.lastCount?.count == Int64(count) }
            #expect(learning.pending.count == (count == 3 ? 1 : 0))
            #expect(try await store.list().isEmpty)
        }
        learning.decide(accept: true)
        try await learningWait { !learning.isSaving }
        let terms = try await store.list()
        #expect(terms.count == 1 && terms.first?.text == "Claude" && terms.first?.source == .automatic)
        try await store.close()
    }

    @Test("自动观察严格限定原输入框，换框、不可读、切换应用都停止", arguments: 0..<3)
    func scope(_ kind: Int) async throws {
        let field = UUID()
        let reader = OutputLearningReader(kind == 1 ? .unavailable(.protectedField)
            : .readable(sample("Cloud", field: kind == 0 ? UUID() : field)))
        let context = OutputCorrectionContext(target: target, baseline: sample("Cloud", field: field), reader: reader)
        let probe = ExternalTextProbeController(trusted: { true }, foregroundPID: { kind == 2 ? 101 : 100 },
                                               isAlive: { _ in true }, interval: .milliseconds(5))
        var samples = 0
        probe.onSample = { _ in samples += 1 }
        probe.startAfterOutput(context)
        try await learningWait { !probe.isRunning }
        #expect(samples == 0)
        if kind == 2 { #expect(await reader.reads == 0) }
    }

    @Test("停止和到时后不再采样，错误进程基线不能启动", arguments: [false, true])
    func boundedLifetime(_ stopManually: Bool) async throws {
        let field = UUID()
        let reader = OutputLearningReader(.readable(sample("Cloud", field: field)))
        let probe = ExternalTextProbeController(trusted: { true }, foregroundPID: { 100 }, isAlive: { _ in true },
                                               duration: stopManually ? .seconds(5) : .milliseconds(30), interval: .milliseconds(5))
        let bad = ExternalTextSnapshot(targetPID: 999, fieldID: field, role: "AXTextArea", text: "Cloud")
        probe.startAfterOutput(OutputCorrectionContext(target: target, baseline: bad, reader: reader))
        #expect(!probe.isRunning)
        probe.startAfterOutput(OutputCorrectionContext(target: target, baseline: sample("Cloud", field: field), reader: reader))
        if stopManually {
            try await learningWait { await reader.reads > 0 }
            probe.stop()
        }
        // 并行测试可能占用主线程超过 30ms；到期用例允许首次调度前已超时，不能要求先读一次。
        try await learningWait { !probe.isRunning }
        let count = await reader.reads
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reader.reads == count)
    }

    @Test("已知输出基线能捕获立即改词；新一轮和失焦清除旧基线")
    func seededBaseline() {
        let field = UUID(), before = sample("Cloud", field: UUID())
        let after = sample("Claude", field: field)
        var observer = StableTermCorrection()
        observer.begin(baseline: sample("Cloud", field: field))
        #expect(observer.receive(after, now: 0) == nil)
        #expect(observer.receive(after, now: 1)?.correctedText == "Claude")
        observer.begin(baseline: before); observer.breakContinuity()
        #expect(observer.receive(after, now: 2) == nil)
        #expect(observer.receive(after, now: 3) == nil)
        observer.begin(baseline: before)
        #expect(observer.receive(after, now: 4) == nil)
        #expect(observer.receive(after, now: 5) == nil)
    }
}
