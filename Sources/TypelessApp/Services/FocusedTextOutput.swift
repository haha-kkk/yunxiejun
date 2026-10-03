import AppKit
import ApplicationServices
import Foundation
import os

protocol TextOutputWriting: Sendable {
    func insert(_ text: String) async throws
    func insertForCorrection(_ text: String) async throws -> OutputCorrectionContext?
}

extension TextOutputWriting {
    func insertForCorrection(_ text: String) async throws -> OutputCorrectionContext? {
        try await insert(text)
        return nil
    }
}

enum TextOutputFailure: Error, Equatable {
    case invalidText, permissionRequired, noTarget, ownApplication, protectedField
    case notEditable, multipleSelections, focusChanged, unavailable, unconfirmed, clipboardRestoreFailed

    var message: String {
        switch self {
        case .invalidText: return "结果为空或过长，未输入。"
        case .permissionRequired: return "需要在系统设置的“辅助功能”中允许 云写君，才能输入文字。"
        case .noTarget: return "当前没有可用的输入框，未输入。"
        case .ownApplication: return "光标仍在本工具中，未输入；请先切到其他应用的输入框。"
        case .protectedField: return "当前是密码输入框，未输入。"
        case .notEditable: return "当前输入框不支持这种文字写入方式，未输入。"
        case .multipleSelections: return "当前有多处文字选区，未输入；请只保留一个光标或选区。"
        case .focusChanged: return "写入前光标位置又变了，未输入。"
        case .unavailable: return "无法确认当前输入框是否可用，未输入。"
        case .clipboardRestoreFailed: return "原剪贴板恢复失败；文字可能已经输入，请检查目标，避免重复输入。"
        case .unconfirmed: return "无法确认是否已输入，请先检查目标输入框，避免重复输入。"
        }
    }
}

struct TextOutputTarget<Handle: Sendable>: Sendable {
    let handle: Handle
    let processID: Int32
    let role: String
    let isProtected: Bool
    let isEnabled: Bool?
    let canReplaceSelection: Bool
    let selectionCount: Int
}

protocol FocusedTextOutputBackend: Sendable {
    associatedtype Handle: Sendable
    func currentTarget() async throws -> TextOutputTarget<Handle>
    /// 必须再次确认前台应用及焦点元素；只写入选区，不替换整个输入框，也不自动重试。
    func commit(_ text: String, to target: TextOutputTarget<Handle>) async throws
    func correctionContext(for target: TextOutputTarget<Handle>) async -> OutputCorrectionContext?
    func paste(_ text: String, to target: TextOutputTarget<Handle>) async throws
}

extension FocusedTextOutputBackend {
    func paste(_ text: String, to target: TextOutputTarget<Handle>) async throws { throw TextOutputFailure.notEditable }
    func correctionContext(for target: TextOutputTarget<Handle>) async -> OutputCorrectionContext? { nil }
}

struct FocusedTextOutputWriter<Backend: FocusedTextOutputBackend>: TextOutputWriting {
    let backend: Backend
    var usesClipboard: @Sendable () -> Bool = { false }

    func insert(_ text: String) async throws {
        _ = try await write(text)
    }

    func insertForCorrection(_ text: String) async throws -> OutputCorrectionContext? {
        let target = try await write(text)
        try Task.checkCancellation()
        return await backend.correctionContext(for: target)
    }

    private func write(_ text: String) async throws -> TextOutputTarget<Backend.Handle> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= TextCleanupResult.maximumOutputBytes else { throw TextOutputFailure.invalidText }
        try Task.checkCancellation()
        // 在结果准备好以后才查询目标，绝不复用开始录音时的输入框。
        let pasteMode = usesClipboard()
        let target = try await backend.currentTarget()
        try Task.checkCancellation()
        guard !target.isProtected else { throw TextOutputFailure.protectedField }
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(target.role),
              target.isEnabled != false, (pasteMode || target.canReplaceSelection) else { throw TextOutputFailure.notEditable }
        guard target.selectionCount == 1 else { throw TextOutputFailure.multipleSelections }
        if pasteMode { try await backend.paste(text, to: target) }
        else { try await backend.commit(text, to: target) }
        return target
    }
}

/// AX 引用只在本 actor 内访问；传出的包装只用于在 commit 时归还同一引用。
struct AXTextOutputHandle: @unchecked Sendable {
    let element: AXUIElement
}

struct TextOutputVerification {
    let text: String
    let range: CFRange

    init(text: String, insertionLocation: Int) throws {
        guard insertionLocation >= 0, insertionLocation <= Int.max - text.utf16.count else {
            throw TextOutputFailure.unavailable
        }
        self.text = text
        range = CFRange(location: insertionLocation, length: text.utf16.count)
    }

    func matches(readback: String?, selection: CFRange) -> Bool {
        guard readback == text else { return false }
        // 常见控件把光标移到插入末尾；少数控件仍选中新插入文字。
        return (selection.location == range.location + range.length && selection.length == 0)
            || (selection.location == range.location && selection.length == range.length)
    }
}

actor MacFocusedTextOutputBackend: FocusedTextOutputBackend {
    private let logger = Logger(subsystem: "local.typeless01.app", category: "text-output")

    func correctionContext(for target: TextOutputTarget<AXTextOutputHandle>) async -> OutputCorrectionContext? {
        guard !Task.isCancelled, await foregroundPID() == target.processID else { return nil }
        // 绑定刚刚写入的 AX 元素，不能在切换输入框后跟着读取新输入框。
        let reader = ExternalTextReader(boundTarget: target)
        guard case .readable(let baseline) = await reader.read(targetPID: target.processID),
              !Task.isCancelled, await foregroundPID() == target.processID else { return nil }
        let app = await MainActor.run { NSRunningApplication(processIdentifier: target.processID)?.localizedName }
        return OutputCorrectionContext(target: ExternalTextTarget(id: target.processID, name: app ?? "输出应用", bundleIdentifier: ""),
                                       baseline: baseline, reader: reader)
    }
    func currentTarget() async throws -> TextOutputTarget<AXTextOutputHandle> {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw TextOutputFailure.permissionRequired }
        guard let pid = await foregroundPID() else { throw TextOutputFailure.noTarget }
        logger.notice("T23 target process: \(pid)")
        guard pid != ProcessInfo.processInfo.processIdentifier else { throw TextOutputFailure.ownApplication }
        let element = try focusedElement(pid: pid)
        let role = try attribute(kAXRoleAttribute, of: element) as? String ?? ""
        let subrole = try attribute(kAXSubroleAttribute, of: element, optional: true) as? String
        guard subrole != kAXSecureTextFieldSubrole else { throw TextOutputFailure.protectedField }
        // TextEdit 的正文不提供 AXEnabled；是否能写入必须由选区可写能力确认。
        // 未提供不等于禁用；明确 false 或属性类型异常仍拒绝。
        let enabledValue = try attribute(kAXEnabledAttribute, of: element, optional: true)
        let enabled = enabledValue as? Bool
        guard enabledValue == nil || enabled != nil else { throw TextOutputFailure.unavailable }
        var settable = DarwinBoolean(false)
        try Task.checkCancellation()
        let writableError = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard [.success, .attributeUnsupported, .notImplemented].contains(writableError) else {
            logger.error("T23 selected-text capability error: \(writableError.rawValue)")
            throw TextOutputFailure.unavailable
        }
        let ranges = try attribute(kAXSelectedTextRangesAttribute, of: element, optional: true)
        let count: Int
        if let ranges {
            guard let array = ranges as? [Any] else {
                logger.error("T23 selected-ranges has unexpected type")
                throw TextOutputFailure.unavailable
            }
            count = array.count
        } else { count = 1 }
        return TextOutputTarget(handle: AXTextOutputHandle(element: element), processID: pid,
                                role: role, isProtected: subrole == kAXSecureTextFieldSubrole,
                                isEnabled: enabled, canReplaceSelection: writableError == .success && settable.boolValue,
                                selectionCount: count)
    }

    func commit(_ text: String, to target: TextOutputTarget<AXTextOutputHandle>) async throws {
        guard AXIsProcessTrusted() else { throw TextOutputFailure.permissionRequired }
        guard await foregroundPID() == target.processID else { throw TextOutputFailure.focusChanged }
        let current = try focusedElement(pid: target.processID)
        guard CFEqual(current, target.handle.element) else { throw TextOutputFailure.focusChanged }
        guard try attribute(kAXSubroleAttribute, of: current, optional: true) as? String != kAXSecureTextFieldSubrole else {
            throw TextOutputFailure.protectedField
        }
        let selection = try selectedRange(of: current)
        let verification = try TextOutputVerification(text: text, insertionLocation: selection.location)
        guard await foregroundPID() == target.processID else { throw TextOutputFailure.focusChanged }
        // 每次 IPC 前检查取消。最后一次检查之后已交给系统的写入无法撤回。
        try Task.checkCancellation()
        let error = AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, text as CFString)
        guard error == .success else {
            // 无响应可能发生在对方已经写入之后，所以绝不重试，也不改用粘贴。
            if error == .cannotComplete { throw TextOutputFailure.unconfirmed }
            throw TextOutputFailure.notEditable
        }
        // Chromium 的接口可能返回 success 却没有修改正文，不能仅凭返回码报成功。
        // 只回读本次应插入的范围，不读取整框；允许渲染进程短暂异步更新，但绝不重写。
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(75))
            guard AXIsProcessTrusted(), await foregroundPID() == target.processID else {
                throw TextOutputFailure.unconfirmed
            }
            do {
                let focused = try focusedElement(pid: target.processID)
                guard CFEqual(focused, current) else { throw TextOutputFailure.unconfirmed }
                guard try attribute(kAXSubroleAttribute, of: current, optional: true) as? String != kAXSecureTextFieldSubrole else {
                    throw TextOutputFailure.unconfirmed
                }
                let readback = try self.text(in: verification.range, of: current)
                if try verification.matches(readback: readback, selection: selectedRange(of: current)) { return }
            } catch is CancellationError { throw CancellationError() }
            catch { /* 只再核对，不再写入。 */ }
        }
        logger.error("T23 write could not be confirmed by range readback")
        throw TextOutputFailure.unconfirmed
    }

    func paste(_ text: String, to target: TextOutputTarget<AXTextOutputHandle>) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw TextOutputFailure.permissionRequired }
        guard await foregroundPID() == target.processID,
              target.processID != ProcessInfo.processInfo.processIdentifier else { throw TextOutputFailure.focusChanged }
        let current = try focusedElement(pid: target.processID)
        guard CFEqual(current, target.handle.element) else { throw TextOutputFailure.focusChanged }
        guard try attribute(kAXSubroleAttribute, of: current, optional: true) as? String != kAXSecureTextFieldSubrole else {
            throw TextOutputFailure.protectedField
        }
        let selection = try selectedRange(of: current)
        let verification = try TextOutputVerification(text: text, insertionLocation: selection.location)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw TextOutputFailure.unavailable
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        // Prepare all clipboard representations before changing any system state.
        let lease = try await MainActor.run { try ClipboardLease(board: NSPasteboard.general, text: text) }
        var posted = false
        do {
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), await foregroundPID() == target.processID,
                  CFEqual(try focusedElement(pid: target.processID), current) else { throw TextOutputFailure.focusChanged }
            let latestSelection = try selectedRange(of: current)
            guard latestSelection.location == selection.location, latestSelection.length == selection.length else {
                throw TextOutputFailure.focusChanged
            }
            // No await between the last checks and posting: one targeted Command-V, never Enter.
            try Task.checkCancellation()
            let sent = await MainActor.run {
                guard !Task.isCancelled, AXIsProcessTrusted(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
                      lease.ownsClipboard else { return false }
                // Re-check the exact element and selection inside this final synchronous step.
                let application = AXUIElementCreateApplication(target.processID)
                AXUIElementSetMessagingTimeout(application, 0.15)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, current) else { return false }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
                var range = CFRange()
                let axRange = value as! AXValue
                guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range),
                      range.location == selection.location, range.length == selection.length else { return false }
                var subrole: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
                guard subrole as? String != kAXSecureTextFieldSubrole else { return false }
                down.postToPid(target.processID); up.postToPid(target.processID)
                return true
            }
            guard sent else { throw TextOutputFailure.focusChanged }
            posted = true
            // A posted paste cannot be cancelled. Let the target consume the clipboard before cleanup.
            // This short independent wait also runs if the session is cancelled after posting.
            await Task.detached { try? await Task.sleep(for: .milliseconds(500)) }.value
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), await foregroundPID() == target.processID,
                  CFEqual(try focusedElement(pid: target.processID), current),
                  try verification.matches(readback: self.text(in: verification.range, of: current),
                                           selection: selectedRange(of: current)) else {
                throw TextOutputFailure.unconfirmed
            }
            guard await MainActor.run(body: { lease.restoreIfOwned() }) else { throw TextOutputFailure.clipboardRestoreFailed }
        } catch {
            guard await MainActor.run(body: { lease.restoreIfOwned() }) else { throw TextOutputFailure.clipboardRestoreFailed }
            // Never use a second writing method after a posted paste, even if readback is unsupported.
            if error as? TextOutputFailure == .clipboardRestoreFailed { throw error }
            if posted && !(error is CancellationError) { throw TextOutputFailure.unconfirmed }
            throw error
        }
    }

    private func foregroundPID() async -> Int32? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    private func focusedElement(pid: Int32) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let value = try attribute(kAXFocusedUIElementAttribute, of: app, optional: true),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw TextOutputFailure.noTarget }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private func selectedRange(of element: AXUIElement) throws -> CFRange {
        guard let value = try attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { throw TextOutputFailure.unavailable }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { throw TextOutputFailure.unavailable }
        return range
    }

    private func text(in range: CFRange, of element: AXUIElement) throws -> String? {
        try Task.checkCancellation()
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { throw TextOutputFailure.unconfirmed }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard error == .success else { throw TextOutputFailure.unconfirmed }
        return value as? String
    }

    private func attribute(_ name: String, of element: AXUIElement, optional: Bool = false) throws -> CFTypeRef? {
        try Task.checkCancellation()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .success { return value }
        if optional, [.attributeUnsupported, .noValue, .notImplemented].contains(error) { return nil }
        logger.error("T23 attribute \(name, privacy: .public) error: \(error.rawValue)")
        throw TextOutputFailure.unavailable
    }
}
