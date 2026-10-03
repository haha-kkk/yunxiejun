import Combine
import Foundation

@MainActor
final class APISettingsController: ObservableObject {
    enum Status: Equatable {
        case unknown, configured, notConfigured

        var label: String {
            switch self {
            case .unknown: return "尚未读取配置"
            case .configured: return "已配置"
            case .notConfigured: return "未配置"
            }
        }
    }

    @Published var draftKey = ""
    @Published private(set) var status: Status = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    let store: any APIKeyStoring

    init(store: any APIKeyStoring = KeychainAPIKeyStore()) { self.store = store }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            status = try await store.isConfigured() ? .configured : .notConfigured
            message = nil
            isError = false
        } catch {
            status = .unknown
            show(error)
        }
    }

    func beginSave() {
        guard let key = prepareSave() else { return }
        Task { await persist(key) }
    }

    func save() async {
        guard let key = prepareSave() else { return }
        await persist(key)
    }

    private func prepareSave() -> String? {
        guard !isBusy else { return nil }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 2048,
              key.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            message = "请输入完整的 API Key，不能包含空格或换行。"
            isError = true
            return nil
        }
        isBusy = true
        draftKey = ""
        return key
    }

    private func persist(_ key: String) async {
        defer { isBusy = false }
        do {
            try await store.save(key)
            status = .configured
            message = "密钥已保存到本机钥匙串。保存不会调用 API，也不验证余额或模型权限。"
            isError = false
        } catch { show(error) }
    }

    func delete() async {
        guard !isBusy else { return }
        isBusy = true
        draftKey = ""
        defer { isBusy = false }
        do {
            try await store.delete()
            status = .notConfigured
            message = "已删除本机保存的密钥；百炼账号中的 Key 仍有效。"
            isError = false
        } catch { show(error) }
    }

    func clearDraft() { draftKey = "" }

    private func show(_ error: Error) {
        // 不显示任意底层异常正文，避免未来服务错误把凭据带入界面或日志。
        message = (error as? KeychainFailure)?.message ?? "密钥操作失败，请重试。"
        isError = true
    }
}
