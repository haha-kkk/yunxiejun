import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func isConfigured() async throws -> Bool
    func read() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}

struct KeychainFailure: Error {
    let status: OSStatus

    var message: String {
        switch status {
        case errSecUserCanceled: return "已取消钥匙串授权，原有配置没有改变。"
        case errSecInteractionNotAllowed: return "无法访问钥匙串，请解锁 Mac 后重试。"
        case errSecAuthFailed: return "钥匙串授权未通过，请重试。"
        default: return "钥匙串操作失败（代码 \(status)），请重试。"
        }
    }
}

/// 只访问本应用在本机登录钥匙串中的百炼凭据，不使用文件或 UserDefaults。
/// actor 将可能等待系统授权的 Security 调用移出主线程。
actor KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account = "bailian-cn-beijing"

    init(service: String = "local.typeless01.app.api-key") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func isConfigured() throws -> Bool {
        var lookup = query
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecReturnAttributes as String] = true
        // 显示“已配置”只读取条目属性，不把已有密钥读回设置页面。
        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    func read() throws -> String? {
        var lookup = query
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw KeychainFailure(status: errSecDecode)
        }
        return key
    }

    func save(_ key: String) throws {
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(update) { _, new in new }
            item[kSecAttrLabel as String] = "云写君 · 百炼北京 API"
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        // 替换失败时保留旧值，不能先删除再添加。
        try check(status)
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
}
