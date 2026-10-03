import ApplicationServices
import Foundation

protocol ExternalTextReading: Sendable {
    func read(targetPID: Int32) async -> ExternalTextReadResult
}

/// 只在成功输出后创建；原输入框身份和基线一起交给纠正计数模块。
struct OutputCorrectionContext: Sendable {
    let target: ExternalTextTarget
    let baseline: ExternalTextSnapshot
    let reader: any ExternalTextReading
}

/// T19 只读指定进程的焦点元素，不遍历窗口、网页或其他应用，不发送按键。
actor ExternalTextReader: ExternalTextReading {
    private var previousElement: AXUIElement?
    private var previousPID: Int32?
    private var fieldID = UUID()
    private let boundTarget: TextOutputTarget<AXTextOutputHandle>?

    init(boundTarget: TextOutputTarget<AXTextOutputHandle>? = nil) { self.boundTarget = boundTarget }

    func read(targetPID: Int32) -> ExternalTextReadResult {
        guard !Task.isCancelled else { return unavailable(.noFocusedField) }
        guard AXIsProcessTrusted() else { return unavailable(.permissionRequired) }
        let application = AXUIElementCreateApplication(targetPID)
        // IPC 放在 actor 内，避免无响应的外部应用卡住本工具窗口。
        AXUIElementSetMessagingTimeout(application, 0.3)
        let (focusError, focusValue) = attribute(kAXFocusedUIElementAttribute, of: application)
        guard focusError == .success, let focusValue else {
            return unavailable(focusError == .noValue ? .noFocusedField : .unreadable(focusError.rawValue))
        }
        guard CFGetTypeID(focusValue) == AXUIElementGetTypeID() else { return unavailable(.noFocusedField) }
        let element = focusValue as! AXUIElement
        if let boundTarget {
            guard targetPID == boundTarget.processID, CFEqual(element, boundTarget.handle.element) else {
                return unavailable(.noFocusedField)
            }
        }
        AXUIElementSetMessagingTimeout(element, 0.3)
        let (roleError, roleValue) = attribute(kAXRoleAttribute, of: element)
        guard roleError == .success, let role = roleValue as? String else { return unavailable(.unreadable(roleError.rawValue)) }
        let (subroleError, subroleValue) = attribute(kAXSubroleAttribute, of: element)
        if subroleValue as? String == kAXSecureTextFieldSubrole { return unavailable(.protectedField) }
        guard [.success, .attributeUnsupported, .noValue].contains(subroleError) else {
            return unavailable(.unreadable(subroleError.rawValue))
        }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            return unavailable(.unsupportedRole(String(role.prefix(80))))
        }
        guard !Task.isCancelled else { return unavailable(.noFocusedField) }
        let (valueError, value) = attribute(kAXValueAttribute, of: element)
        guard valueError == .success else { return unavailable(.unreadable(valueError.rawValue)) }
        guard let text = value as? String else { return unavailable(.nonTextValue) }
        guard text.utf16.count <= 16000 else { return unavailable(.tooLong) }
        if previousPID != targetPID || previousElement.map({ !CFEqual($0, element) }) != false {
            fieldID = UUID()
        }
        previousPID = targetPID; previousElement = element
        return .readable(ExternalTextSnapshot(targetPID: targetPID, fieldID: fieldID, role: role, text: text))
    }

    private func attribute(_ name: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private func unavailable(_ issue: ExternalTextReadIssue) -> ExternalTextReadResult {
        previousElement = nil; previousPID = nil
        return .unavailable(issue)
    }
}
