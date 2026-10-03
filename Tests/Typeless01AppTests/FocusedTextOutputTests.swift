import ApplicationServices
import Foundation
import Testing
@testable import Typeless01App

private actor OutputBackend: FocusedTextOutputBackend {
    var field = 1
    var role = kAXTextAreaRole
    var protected = false
    var enabled: Bool? = true
    var settable = true
    var selections = 1
    var prepareError: TextOutputFailure?
    var commitError: TextOutputFailure?
    var prepareCalls = 0
    var pasteCalls = 0
    var pasteError: TextOutputFailure?
    var commits = 0
    var writes: [(Int, String)] = []
    var pausePrepare = false
    var pauseCommit = false
    var pending: CheckedContinuation<Void, Never>?

    func configure(field: Int = 1, role: String = kAXTextAreaRole, protected: Bool = false,
                   enabled: Bool? = true, settable: Bool = true, selections: Int = 1,
                   prepareError: TextOutputFailure? = nil, commitError: TextOutputFailure? = nil,
                   pausePrepare: Bool = false, pauseCommit: Bool = false) {
        self.field = field; self.role = role; self.protected = protected; self.enabled = enabled
        self.settable = settable; self.selections = selections; self.prepareError = prepareError
        self.commitError = commitError; self.pausePrepare = pausePrepare; self.pauseCommit = pauseCommit
    }
    func setPasteError(_ error: TextOutputFailure) { pasteError = error }
    func paste(_ text: String, to target: TextOutputTarget<Int>) async throws {
        pasteCalls += 1
        guard field == target.handle else { throw TextOutputFailure.focusChanged }
        if let pasteError { throw pasteError }
        writes.append((field, text))
    }
    func move(to field: Int) { self.field = field }
    func resume() { pending?.resume(); pending = nil }
    func currentTarget() async throws -> TextOutputTarget<Int> {
        prepareCalls += 1
        if let prepareError { throw prepareError }
        let target = TextOutputTarget(handle: field, processID: 200, role: role, isProtected: protected,
                                     isEnabled: enabled, canReplaceSelection: settable, selectionCount: selections)
        if pausePrepare { await withCheckedContinuation { pending = $0 } }
        return target
    }
    func commit(_ text: String, to target: TextOutputTarget<Int>) async throws {
        commits += 1
        if pauseCommit { await withCheckedContinuation { pending = $0 } }
        try Task.checkCancellation()
        guard field == target.handle else { throw TextOutputFailure.focusChanged }
        if let commitError { throw commitError }
        writes.append((field, text))
    }
}

private actor OutputCleaner: TextCleaning {
    var calls = 0
    var pending: CheckedContinuation<TextCleanupResult, Error>?
    func clean(_ text: String) async throws -> TextCleanupResult {
        calls += 1
        // 故意忽略取消，以验证已过期的 API 回调没有交付资格。
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(original: String = "原文", output: String = "整理结果") throws {
        pending?.resume(returning: try TextCleanupResult(request: TextCleanupRequest(originalText: original), output: output))
        pending = nil
    }
    func fail() { pending?.resume(throwing: URLError(.notConnectedToInternet)); pending = nil }
}

private func awaitOutput(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待输出测试状态超时")
    throw CancellationError()
}

@Suite("T23 当前光标输出边界")
struct FocusedTextOutputTests {
    @Test("写入核验按 UTF16 处理表情，拒绝 Chrome 成功但正文未变的响应")
    func verifiesActualInsertion() throws {
        let text = "中文 👩🏽‍💻\n下一行"
        let check = try TextOutputVerification(text: text, insertionLocation: 3)
        #expect(check.matches(readback: text, selection: CFRange(location: 3 + text.utf16.count, length: 0)))
        #expect(check.matches(readback: text, selection: CFRange(location: 3, length: text.utf16.count)))
        #expect(!check.matches(readback: "原来的文字", selection: CFRange(location: 3, length: 0)))
        #expect(!check.matches(readback: nil, selection: CFRange(location: 3 + text.utf16.count, length: 0)))
        #expect(!check.matches(readback: text, selection: CFRange(location: 3, length: 0)))
        #expect(throws: TextOutputFailure.unavailable) { try TextOutputVerification(text: text, insertionLocation: -1) }
        #expect(throws: TextOutputFailure.unavailable) { try TextOutputVerification(text: text, insertionLocation: Int.max) }
    }

    @Test("空白、空串、过长文字不查询输入框", arguments: ["", " \n", String(repeating: "中", count: 10_923)])
    func invalidText(_ text: String) async {
        let backend = OutputBackend()
        await #expect(throws: TextOutputFailure.invalidText) {
            try await FocusedTextOutputWriter(backend: backend).insert(text)
        }
        #expect(await backend.prepareCalls == 0)
        #expect(await backend.writes.isEmpty)
    }

    @Test("中文、表情、换行和首尾空格原样写入且只写一次")
    func exactText() async throws {
        let backend = OutputBackend()
        let text = " 第一行：Claude 👩🏽‍💻\n第二行，不要发送。 "
        try await FocusedTextOutputWriter(backend: backend).insert(text)
        #expect(await backend.writes.count == 1)
        #expect(await backend.writes.first?.1 == text)
    }

    @Test("密码、禁用、只读、非输入框、多选区均不写入", arguments: 0..<5)
    func refusesUnsafeTarget(_ kind: Int) async {
        let backend = OutputBackend()
        switch kind {
        case 0: await backend.configure(protected: true)
        case 1: await backend.configure(enabled: false)
        case 2: await backend.configure(settable: false)
        case 3: await backend.configure(role: kAXButtonRole)
        default: await backend.configure(selections: 2)
        }
        await #expect(throws: TextOutputFailure.self) { try await FocusedTextOutputWriter(backend: backend).insert("结果") }
        #expect(await backend.commits == 0)
    }

    @Test("权限、无焦点和本工具焦点错误不会尝试写入", arguments: [TextOutputFailure.permissionRequired, .noTarget, .ownApplication])
    func targetErrors(_ error: TextOutputFailure) async {
        let backend = OutputBackend()
        await backend.configure(prepareError: error)
        await #expect(throws: error) { try await FocusedTextOutputWriter(backend: backend).insert("结果") }
        #expect(await backend.commits == 0)
    }

    @Test("TextEdit 未提供启用属性时，仅可写选区允许输入", arguments: [false, true])
    func absentEnabled(_ writable: Bool) async throws {
        let backend = OutputBackend()
        await backend.configure(enabled: nil, settable: writable)
        let writer = FocusedTextOutputWriter(backend: backend)
        if writable {
            try await writer.insert("TextEdit 兼容样例")
            #expect(await backend.writes.first?.1 == "TextEdit 兼容样例")
        } else {
            await #expect(throws: TextOutputFailure.notEditable) { try await writer.insert("不得写入") }
            #expect(await backend.writes.isEmpty)
        }
    }

    @Test("查询输入框期间取消，不调用写入")
    func cancelledLookup() async throws {
        let backend = OutputBackend()
        await backend.configure(pausePrepare: true)
        let task = Task { try await FocusedTextOutputWriter(backend: backend).insert("结果") }
        try await awaitOutput { await backend.pending != nil }
        task.cancel(); await backend.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.commits == 0)
    }

    @Test("查到输入框后焦点再次变化，放弃写入")
    func changedFocus() async throws {
        let backend = OutputBackend()
        await backend.configure(pausePrepare: true)
        let task = Task { try await FocusedTextOutputWriter(backend: backend).insert("结果") }
        try await awaitOutput { await backend.pending != nil }
        await backend.move(to: 2); await backend.resume()
        await #expect(throws: TextOutputFailure.focusChanged) { try await task.value }
        #expect(await backend.writes.isEmpty)
    }

    @Test("写入结果不确定时不自动重试")
    func noRetry() async {
        let backend = OutputBackend()
        await backend.configure(commitError: .unconfirmed)
        await #expect(throws: TextOutputFailure.unconfirmed) { try await FocusedTextOutputWriter(backend: backend).insert("结果") }
        #expect(await backend.commits == 1)
    }
}

@Suite("T23 整理后输出时机与取消")
@MainActor
struct CleanupOutputTests {
    @Test("本地输出验证不调用模型，并明确标注未整理")
    func localOutputTest() async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "嗯，这是本地测试。"
        controller.begin(preparationDelay: .zero, localOutputTest: true)
        try await awaitOutput { !controller.isBusy }
        #expect(await service.calls == 0)
        #expect(await backend.writes.first?.1 == "嗯，这是本地测试。")
        #expect(controller.isLocalOutputTest && controller.status.contains("没有调用 API"))
        controller.input = "下一次真实整理"
        #expect(!controller.isLocalOutputTest)
    }

    @Test("普通整理不向外输入")
    func noImplicitOutput() async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin()
        try await awaitOutput { await service.calls == 1 }
        try await service.complete()
        try await awaitOutput { !controller.isBusy }
        #expect(controller.state == .completed && controller.outputStatus == nil)
        #expect(await backend.prepareCalls == 0)
    }

    @Test("只在结果完成后查询最终光标，重复点击不重复输出")
    func finalCursor() async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin(outputToCursor: true, preparationDelay: .zero)
        controller.begin(outputToCursor: true, preparationDelay: .zero)
        try await awaitOutput { await service.calls == 1 }
        #expect(await backend.prepareCalls == 0)
        await backend.move(to: 2)
        try await service.complete()
        try await awaitOutput { !controller.isBusy }
        #expect(await backend.writes.count == 1)
        #expect(await backend.writes.first?.0 == 2)
        #expect(controller.result?.cleanedText == "整理结果")
        #expect(controller.outputStatus?.contains("已输入") == true)
    }

    @Test("无法写入时保留完整结果和原文", arguments: [TextOutputFailure.permissionRequired, .noTarget, .unconfirmed])
    func outputFailure(_ failure: TextOutputFailure) async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        await backend.configure(prepareError: failure)
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin(outputToCursor: true, preparationDelay: .zero)
        try await awaitOutput { await service.calls == 1 }; try await service.complete()
        try await awaitOutput { !controller.isBusy }
        #expect(controller.state == .completed && controller.input == "原文")
        #expect(controller.result?.cleanedText == "整理结果")
        #expect(controller.outputStatus?.contains(failure.message) == true)
        #expect(await backend.writes.isEmpty)
    }

    @Test("准备阶段取消不请求 API、不输出")
    func preparationCancelled() async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin(outputToCursor: true)
        #expect(controller.state == .preparingOutput && controller.isBusy)
        controller.cancelIfActive()
        for _ in 0..<20 { await Task.yield() }
        #expect(await service.calls == 0)
        #expect(await backend.prepareCalls == 0)
        #expect(controller.state == .cancelled)
    }

    @Test("取消、改原文或 API 超时之后的迟到结果不能写入", arguments: 0..<3)
    func lateResult(_ kind: Int) async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, timeout: .milliseconds(50), writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin(outputToCursor: true, preparationDelay: .zero)
        try await awaitOutput { await service.calls == 1 }
        if kind == 0 { controller.cancelIfActive() }
        else if kind == 1 { controller.input = "新原文" }
        else { try await awaitOutput { !controller.isBusy } }
        try await service.complete()
        for _ in 0..<20 { await Task.yield() }
        #expect(await backend.prepareCalls == 0)
        #expect(controller.result == nil && controller.outputStatus == nil)
    }

    @Test("写入准备期间取消或超时，不产生迟到写入", arguments: [false, true])
    func lateWrite(_ timeout: Bool) async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        await backend.configure(pauseCommit: true)
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend), outputTimeout: .milliseconds(50))
        controller.input = "原文"; controller.begin(outputToCursor: true, preparationDelay: .zero)
        try await awaitOutput { await service.calls == 1 }; try await service.complete()
        try await awaitOutput { await backend.pending != nil }
        if timeout { try await awaitOutput { !controller.isBusy } } else { controller.cancelIfActive() }
        await backend.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(await backend.writes.isEmpty)
        if timeout {
            #expect(controller.result?.cleanedText == "整理结果")
            #expect(controller.outputStatus?.contains("超时") == true)
        } else {
            #expect(controller.state == .cancelled && controller.result == nil)
        }
    }

    @Test("网络失败与错配原文不尝试输出", arguments: [false, true])
    func failedCleanup(_ mismatch: Bool) async throws {
        let service = OutputCleaner(), backend = OutputBackend()
        let controller = TextCleanupController(service: service, writer: FocusedTextOutputWriter(backend: backend))
        controller.input = "原文"; controller.begin(outputToCursor: true, preparationDelay: .zero)
        try await awaitOutput { await service.calls == 1 }
        if mismatch { try await service.complete(original: "其他原文") } else { await service.fail() }
        try await awaitOutput { !controller.isBusy }
        #expect(await backend.prepareCalls == 0)
        #expect(controller.result == nil && controller.outputStatus == nil)
    }
}

@Suite("兼容输入路由")
struct CompatibilityOutputTests {
    @Test("兼容模式在写入前选择一次粘贴，不尝试 AX 写入")
    func choosesPasteBeforeWriting() async throws {
        let backend = OutputBackend()
        await backend.configure(settable: false)
        try await FocusedTextOutputWriter(backend: backend, usesClipboard: { true }).insert("测试 👩🏽‍💻")
        #expect(await backend.pasteCalls == 1)
        #expect(await backend.commits == 0)
        #expect(await backend.writes.first?.1 == "测试 👩🏽‍💻")
    }
    @Test("粘贴结果未确认时不补写、不重试")
    func noSecondWrite() async {
        let backend = OutputBackend()
        await backend.setPasteError(.unconfirmed)
        await #expect(throws: TextOutputFailure.unconfirmed) {
            try await FocusedTextOutputWriter(backend: backend, usesClipboard: { true }).insert("测试")
        }
        #expect(await backend.pasteCalls == 1)
        #expect(await backend.commits == 0)
    }
    @Test("兼容模式仍拒绝密码、禁用、非输入框、多选区", arguments: 0..<4)
    func protectedTargets(_ kind: Int) async {
        let backend = OutputBackend()
        switch kind {
        case 0: await backend.configure(protected: true)
        case 1: await backend.configure(enabled: false)
        case 2: await backend.configure(role: kAXButtonRole)
        default: await backend.configure(selections: 2)
        }
        await #expect(throws: TextOutputFailure.self) {
            try await FocusedTextOutputWriter(backend: backend, usesClipboard: { true }).insert("不得输入")
        }
        #expect(await backend.pasteCalls == 0)
        #expect(await backend.commits == 0)
    }
}
