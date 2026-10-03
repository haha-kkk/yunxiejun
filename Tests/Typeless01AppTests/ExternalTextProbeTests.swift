import Foundation
import Testing
@testable import Typeless01App

private actor ProbeReader: ExternalTextReading {
    private var pending: [CheckedContinuation<ExternalTextReadResult, Never>] = []
    private(set) var targets: [Int32] = []

    func read(targetPID: Int32) async -> ExternalTextReadResult {
        targets.append(targetPID)
        // 故意忽略任务取消，验证控制器不会接收旧任务的迟到结果。
        return await withCheckedContinuation { pending.append($0) }
    }
    func reply(_ result: ExternalTextReadResult) { pending.removeFirst().resume(returning: result) }
}

@Suite("T19 外部输入框采样比较")
struct ExternalTextComparisonTests {
    @Test("只比较同一进程同一输入框，原样保留空白、中文和 emoji")
    func fieldIdentityAndExactText() {
        var comparison = ExternalTextComparison()
        let field = UUID()
        func sample(_ text: String, pid: Int32 = 1, id: UUID? = nil) -> ExternalTextSnapshot {
            ExternalTextSnapshot(targetPID: pid, fieldID: id ?? field, role: "AXTextArea", text: text)
        }
        #expect(comparison.receive(sample("")) == nil)
        let typed = comparison.receive(sample(" 请用 Cloud 👩‍💻 整理需求。\n"))
        #expect(typed?.before == "" && typed?.after == " 请用 Cloud 👩‍💻 整理需求。\n")
        #expect(comparison.receive(sample(" 请用 Cloud 👩‍💻 整理需求。\n")) == nil)
        let corrected = comparison.receive(sample(" 请用 Claude 👩‍💻 整理需求。\n"))
        #expect(corrected?.before == typed?.after && corrected?.after == " 请用 Claude 👩‍💻 整理需求。\n")
        #expect(comparison.receive(sample("其他输入框", id: UUID())) == nil)
        #expect(comparison.receive(sample("其他应用", pid: 2)) == nil)
        comparison.reset()
        #expect(comparison.receive(sample("新基线")) == nil)
    }
}

@Suite("T19 验证状态、权限与读取范围")
@MainActor
struct ExternalTextProbeTests {
    private let target = ExternalTextTarget(id: 1234, name: "测试应用", bundleIdentifier: "test.only")
    private func sample(_ text: String, field: UUID) -> ExternalTextReadResult {
        .readable(ExternalTextSnapshot(targetPID: target.id, fieldID: field, role: "AXTextArea", text: text))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待输入框验证测试超时")
        throw CancellationError()
    }

    @Test("没有权限或目标已退出时不读取任何文本")
    func permissionAndLivenessGate() async {
        let reader = ProbeReader()
        let denied = ExternalTextProbeController(reader: reader, trusted: { false }, foregroundPID: { 1234 }, isAlive: { _ in true })
        denied.start(target)
        #expect(!denied.isRunning && denied.status == ExternalTextReadIssue.permissionRequired.message)
        let exited = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { 1234 }, isAlive: { _ in false })
        exited.start(target)
        #expect(!exited.isRunning && exited.status.contains("退出"))
        #expect(await reader.targets.isEmpty)
    }

    @Test("只读所选前台进程，读取期间切走的结果丢弃；恢复焦点后重建基线")
    func foregroundScope() async throws {
        let reader = ProbeReader(), field = UUID()
        var foreground: Int32? = 9999
        let controller = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { foreground }, isAlive: { _ in true }, interval: .milliseconds(20))
        controller.start(target)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await reader.targets.isEmpty)
        foreground = target.id
        try await waitUntil { await reader.targets.count == 1 }
        foreground = 9999
        await reader.reply(sample("不能采用的迟到文字", field: field))
        try await waitUntil { controller.status.contains("暂停") }
        #expect(controller.snapshot == nil && controller.changes.isEmpty)
        foreground = target.id
        try await waitUntil { await reader.targets.count == 2 }
        await reader.reply(sample("Cloud", field: field))
        try await waitUntil { await reader.targets.count == 3 }
        await reader.reply(sample("Claude", field: field))
        try await waitUntil { controller.changes.count == 1 }
        #expect(controller.changes.first?.before == "Cloud" && controller.changes.first?.after == "Claude")
        try await waitUntil { await reader.targets.count == 4 }
        controller.stop()
        await reader.reply(sample("停止后不得显示", field: field))
        #expect(controller.snapshot?.text == "Claude")
        #expect(await reader.targets.allSatisfy { $0 == target.id })
    }

    @Test("不可读、密码框和不同字段之间不拼接修改记录，空输入框仍是成功读取")
    func readGaps() async throws {
        let reader = ProbeReader(), field = UUID()
        let controller = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { 1234 }, isAlive: { _ in true }, interval: .milliseconds(20))
        controller.start(target)
        try await waitUntil { await reader.targets.count == 1 }
        await reader.reply(sample("Cloud", field: field))
        try await waitUntil { await reader.targets.count == 2 }
        await reader.reply(.unavailable(.protectedField))
        try await waitUntil { controller.status == ExternalTextReadIssue.protectedField.message }
        try await waitUntil { await reader.targets.count == 3 }
        await reader.reply(sample("Claude", field: field))
        try await waitUntil { await reader.targets.count == 4 }
        #expect(controller.changes.isEmpty)
        await reader.reply(sample("", field: UUID()))
        try await waitUntil { await reader.targets.count == 5 }
        #expect(controller.snapshot?.text == "" && controller.changes.isEmpty)
        await reader.reply(.unavailable(.unreadable(-25204)))
        try await waitUntil { controller.status.contains("-25204") }
        #expect(controller.status.contains("-25204"))
        try await waitUntil { await reader.targets.count == 6 }
        controller.stop(); await reader.reply(.unavailable(.noFocusedField))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.lastReadStatus.contains("-25204"))
        #expect(controller.readAttempts == 6 && controller.successfulReads == 3)
        controller.clearResults()
        #expect(controller.readAttempts == 0 && controller.successfulReads == 0)
        #expect(controller.lastReadStatus == "尚未读取目标输入框。")
    }

    @Test("停止后立即重开，旧成功响应不能混入新验证")
    func staleRun() async throws {
        let reader = ProbeReader(), field = UUID()
        let controller = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { 1234 }, isAlive: { _ in true }, interval: .milliseconds(2))
        controller.start(target)
        try await waitUntil { await reader.targets.count == 1 }
        controller.start(target) // 连点开始也不得多开一条读取任务。
        controller.stop(); controller.start(target)
        try await waitUntil { await reader.targets.count == 2 }
        await reader.reply(sample("旧任务", field: field))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.snapshot == nil && controller.isRunning)
        await reader.reply(sample("新任务", field: field))
        try await waitUntil { await reader.targets.count == 3 }
        #expect(controller.snapshot?.text == "新任务")
        controller.clearResults()
        await reader.reply(sample("清空后迟到", field: field))
        for _ in 0..<20 { await Task.yield() }
        #expect(!controller.isRunning && controller.snapshot == nil && controller.changes.isEmpty)
    }

    @Test("权限撤销、目标退出和读取超过截止时间都拒绝迟到内容")
    func interruptionWhileReading() async throws {
        for mode in 0..<3 {
            let reader = ProbeReader(), field = UUID()
            var trusted = true, alive = true
            let controller = ExternalTextProbeController(reader: reader, trusted: { trusted }, foregroundPID: { 1234 }, isAlive: { _ in alive }, duration: mode == 2 ? .milliseconds(30) : .seconds(60), interval: .milliseconds(2))
            controller.start(target)
            try await waitUntil { await reader.targets.count == 1 }
            if mode == 0 { trusted = false }
            if mode == 1 { alive = false }
            if mode == 2 { try await Task.sleep(for: .milliseconds(45)) }
            await reader.reply(sample("不得接收", field: field))
            try await waitUntil { !controller.isRunning }
            #expect(controller.snapshot == nil && controller.changes.isEmpty)
            if mode == 0 { #expect(!controller.hasPermission) }
        }
    }

    @Test("观察记录最多五条；切走直到到时不会读取其他应用")
    func boundedHistoryAndDeadline() async throws {
        let reader = ProbeReader(), field = UUID()
        let controller = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { 1234 }, isAlive: { _ in true }, interval: .milliseconds(2))
        controller.start(target)
        for index in 0..<8 {
            try await waitUntil { await reader.targets.count == index + 1 }
            await reader.reply(sample("词条 \(index)", field: field))
        }
        try await waitUntil { await reader.targets.count == 9 }
        #expect(controller.changes.count == 5 && controller.changes.first?.after == "词条 7")
        controller.stop(); await reader.reply(.unavailable(.noFocusedField))
        let inactive = ExternalTextProbeController(reader: reader, trusted: { true }, foregroundPID: { 9999 }, isAlive: { _ in true }, duration: .milliseconds(25), interval: .milliseconds(2))
        inactive.start(target)
        try await waitUntil { !inactive.isRunning }
        #expect(inactive.status.contains("到时"))
        #expect(await reader.targets.count == 9)
    }
}
