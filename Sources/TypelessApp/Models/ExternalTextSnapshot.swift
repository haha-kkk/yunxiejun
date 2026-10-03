import Foundation

struct ExternalTextTarget: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    let bundleIdentifier: String
}

struct ExternalTextSnapshot: Equatable, Sendable {
    let targetPID: Int32
    let fieldID: UUID
    let role: String
    let text: String
}

enum ExternalTextReadIssue: Equatable, Sendable {
    case permissionRequired, noFocusedField, protectedField, unsupportedRole(String)
    case unreadable(Int32), nonTextValue, tooLong

    var message: String {
        switch self {
        case .permissionRequired: return "缺少辅助功能权限，请在系统设置中允许本应用，然后重新开始。"
        case .noFocusedField: return "未找到聚焦输入框，请点击所选应用中的文本输入区域。"
        case .protectedField: return "这是受保护的密码输入框，已跳过读取。"
        case .unsupportedRole(let role): return "当前元素不是可验证的文本框（\(role)），请点击输入框；若仍如此，该输入框暂不支持。"
        case .unreadable(let code): return "当前应用没有返回可读取的输入框文字（代码 \(code)）；可能暂时忙或不支持。"
        case .nonTextValue: return "输入框没有提供文字值，本次无法验证。"
        case .tooLong: return "文字超过 16000 个 UTF-16 单元，本次验证已跳过；请使用简短测试句。"
        }
    }
}

enum ExternalTextReadResult: Sendable {
    case readable(ExternalTextSnapshot)
    case unavailable(ExternalTextReadIssue)
}

struct ExternalTextChange: Identifiable, Equatable {
    let id = UUID()
    let before: String
    let after: String
}

/// 只比较同一次验证、同一输入框的连续可读采样；中间失焦或不可读就重新建立基线。
struct ExternalTextComparison {
    private var baseline: ExternalTextSnapshot?

    mutating func reset() { baseline = nil }

    mutating func receive(_ sample: ExternalTextSnapshot) -> ExternalTextChange? {
        defer { baseline = sample }
        guard let old = baseline, old.targetPID == sample.targetPID, old.fieldID == sample.fieldID,
              old.text != sample.text else { return nil }
        return ExternalTextChange(before: old.text, after: sample.text)
    }
}
