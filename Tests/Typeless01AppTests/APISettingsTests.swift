import Foundation
import Security
import Testing
@testable import Typeless01App

private actor MemoryKeyStore: APIKeyStoring {
    var key: String?
    var error: Error?
    var reads = 0
    var saves = 0
    var paused = false
    var pending: CheckedContinuation<Void, Never>?

    func isConfigured() throws -> Bool { if let error { throw error }; return key != nil }
    func read() throws -> String? { reads += 1; if let error { throw error }; return key }
    func save(_ value: String) async throws {
        saves += 1
        if paused { await withCheckedContinuation { pending = $0 } }
        if let error { throw error }
        key = value
    }
    func delete() throws { if let error { throw error }; key = nil }
    func setError(_ value: Error?) { error = value }
    func pause() { paused = true }
    func resume() { paused = false; pending?.resume(); pending = nil }
}

@Suite("T10 本机钥匙串集成")
struct KeychainIntegrationTests {
    @Test("隔离测试条目的增读改删和命名空间隔离",
          .enabled(if: ProcessInfo.processInfo.environment["TYPELESS_KEYCHAIN_INTEGRATION"] == "1"))
    func roundTrip() async throws {
        let name = "local.typeless01.tests." + UUID().uuidString
        let first = KeychainAPIKeyStore(service: name + ".first")
        let second = KeychainAPIKeyStore(service: name + ".second")
        do {
            #expect(try await !first.isConfigured())
            try await first.save("disposable-test-value-1")
            try await second.save("disposable-test-value-2")
            let reopened = KeychainAPIKeyStore(service: name + ".first")
            #expect(try await reopened.isConfigured())
            #expect(try await reopened.read() == "disposable-test-value-1")
            try await reopened.save("disposable-test-value-replaced")
            #expect(try await first.read() == "disposable-test-value-replaced")
            try await first.delete()
            try await first.delete()
            #expect(try await first.read() == nil)
            #expect(try await !first.isConfigured())
            #expect(try await second.read() == "disposable-test-value-2")
        } catch {
            try? await first.delete()
            try? await second.delete()
            throw error
        }
        try await second.delete()
    }
}

@Suite("T10 API 密钥设置")
@MainActor
struct APISettingsTests {
    @Test("没有密钥时显示未配置；状态刷新不读取密钥正文")
    func initialStatus() async {
        let store = MemoryKeyStore()
        let controller = APISettingsController(store: store)
        await controller.refresh()
        #expect(controller.status == .notConfigured)
        #expect(await store.reads == 0)
        #expect(!controller.isBusy)
    }

    @Test("保存清空输入，新建控制器仍能看到已配置且不会回填密钥")
    func saveAndReopen() async throws {
        let store = MemoryKeyStore()
        let controller = APISettingsController(store: store)
        controller.draftKey = "  example-test-key\n"
        await controller.save()
        #expect(controller.status == .configured)
        #expect(controller.draftKey.isEmpty)
        #expect(try await store.read() == "example-test-key")
        let reopened = APISettingsController(store: store)
        await reopened.refresh()
        #expect(reopened.status == .configured)
        #expect(reopened.draftKey.isEmpty)
    }

    @Test("空白、含换行空格、非 ASCII 和过长密钥不写入")
    func invalidInput() async {
        let store = MemoryKeyStore()
        let controller = APISettingsController(store: store)
        for key in ["", " \n", "abc def", "abc\ndef", "中文", String(repeating: "a", count: 2049)] {
            controller.draftKey = key
            await controller.save()
            #expect(controller.isError)
        }
        #expect(await store.saves == 0)
    }

    @Test("替换保存失败时保留旧密钥，不把失败显示为成功")
    func failedReplacement() async throws {
        let store = MemoryKeyStore()
        try await store.save("old-test-key")
        let controller = APISettingsController(store: store)
        await controller.refresh()
        await store.setError(KeychainFailure(status: errSecAuthFailed))
        controller.draftKey = "new-test-key"
        await controller.save()
        #expect(controller.status == .configured)
        #expect(controller.isError)
        #expect(controller.draftKey.isEmpty)
        await store.setError(nil)
        #expect(try await store.read() == "old-test-key")
    }

    @Test("删除成功后为未配置，重复删除安全")
    func deleteKey() async throws {
        let store = MemoryKeyStore()
        try await store.save("example-test-key")
        let controller = APISettingsController(store: store)
        await controller.refresh()
        await controller.delete()
        await controller.delete()
        #expect(controller.status == .notConfigured)
        #expect(try await store.read() == nil)
    }

    @Test("删除失败不谎报未配置")
    func failedDelete() async throws {
        let store = MemoryKeyStore()
        try await store.save("example-test-key")
        let controller = APISettingsController(store: store)
        await controller.refresh()
        await store.setError(KeychainFailure(status: errSecInteractionNotAllowed))
        await controller.delete()
        #expect(controller.status == .configured)
        #expect(controller.isError)
    }

    @Test("读取失败显示未知，不误判成密钥丢失；允许重试")
    func failedRefresh() async throws {
        let store = MemoryKeyStore()
        try await store.save("example-test-key")
        let controller = APISettingsController(store: store)
        await store.setError(KeychainFailure(status: errSecUserCanceled))
        await controller.refresh()
        #expect(controller.status == .unknown)
        #expect(controller.isError)
        await store.setError(nil)
        await controller.refresh()
        #expect(controller.status == .configured)
        #expect(!controller.isError)
    }

    @Test("保存尚未结束时拒绝重复保存、删除和刷新")
    func avoidConcurrentOperations() async {
        let store = MemoryKeyStore()
        await store.pause()
        let controller = APISettingsController(store: store)
        controller.draftKey = "example-test-key"
        let save = Task { await controller.save() }
        while await store.pending == nil { await Task.yield() }
        #expect(controller.isBusy)
        await controller.save()
        await controller.delete()
        await controller.refresh()
        #expect(await store.saves == 1)
        await store.resume()
        await save.value
        #expect(controller.status == .configured)
        #expect(!controller.isBusy)
    }

    @Test("关闭设置清空草稿，不删除已有配置")
    func clearDraft() async throws {
        let store = MemoryKeyStore()
        try await store.save("saved-test-key")
        let controller = APISettingsController(store: store)
        controller.draftKey = "unsaved-test-key"
        controller.clearDraft()
        #expect(controller.draftKey.isEmpty)
        #expect(try await store.read() == "saved-test-key")
    }

    @Test("点击保存后立即关闭设置，已确认的保存不丢失")
    func closeImmediatelyAfterSave() async throws {
        let store = MemoryKeyStore()
        let controller = APISettingsController(store: store)
        controller.draftKey = "confirmed-test-key"
        controller.beginSave()
        #expect(controller.isBusy)
        controller.clearDraft()
        while controller.isBusy { await Task.yield() }
        #expect(controller.status == .configured)
        #expect(try await store.read() == "confirmed-test-key")
    }

    @Test("任意底层异常文本不显示给用户")
    func redactedError() async {
        struct SensitiveFailure: Error, CustomStringConvertible {
            var description: String { "secret-test-value" }
        }
        let store = MemoryKeyStore()
        await store.setError(SensitiveFailure())
        let controller = APISettingsController(store: store)
        await controller.refresh()
        #expect(controller.message == "密钥操作失败，请重试。")
    }
}
