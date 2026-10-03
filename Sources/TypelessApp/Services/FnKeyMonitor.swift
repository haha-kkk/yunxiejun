import AppKit
import Combine
import CoreGraphics
import Foundation

final class FnKeyMonitor: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var status = "尚未开始监听"
    @Published private(set) var events: [FnKeyEvent] = []
    // event tap 安装在主线程 run loop；取消直接执行，不排队到下一次会话。
    var onEscape: (@MainActor () -> Void)?
    var onFnTap: (@MainActor () -> Void)?
    var onListeningStopped: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnGesture = FnGesture()
    private var localKeyMonitor: Any?

    var hasListenPermission: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func start() -> Bool {
        if let eventTap {
            if CGEvent.tapIsEnabled(tap: eventTap) {
                isListening = true
                status = "正在监听 Fn / Esc；可切换到其他应用测试"
                return true
            }

            CGEvent.tapEnable(tap: eventTap, enable: true)
            if CGEvent.tapIsEnabled(tap: eventTap) {
                isListening = true
                status = "按键监听已恢复"
                return true
            }

            removeEventTap()
        }

        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            status = "需要 macOS 输入监控权限才能检测 Fn / Esc"
            return false
        }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    monitor.resetPendingFn()
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        if CGEvent.tapIsEnabled(tap: tap) {
                            monitor.isListening = true
                            monitor.status = "系统暂停了按键监听，已恢复"
                        } else {
                            monitor.isListening = false
                            monitor.status = "按键监听已暂停，请重新开始；仍失败时检查输入监控权限"
                            MainActor.assumeIsolated { monitor.onListeningStopped?() }
                        }
                    }
                case .flagsChanged:
                    monitor.handleFlagsChanged(event)
                case .keyDown:
                    monitor.fnGesture.keyDown(event.getIntegerValueField(.keyboardEventKeycode))
                    if FnKeyMonitor.isEscapePress(
                        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        flags: event.flags
                    ) {
                        MainActor.assumeIsolated {
                            // 本应用前台时由本地事件监视器处理，避免同一次按键取消两次。
                            if !NSApplication.shared.isActive { monitor.handleEscape() }
                        }
                    }
                case .keyUp:
                    monitor.fnGesture.keyUp(event.getIntegerValueField(.keyboardEventKeycode))
                default:
                    break
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = "macOS 未能创建键盘监听器，请检查输入监控权限"
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            status = "macOS 未能启动键盘监听器，请重试"
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            removeEventTap()
            status = "键盘监听未能启用，请检查输入监控权限"
            return false
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if FnKeyMonitor.isEscapePress(
                keyCode: Int64(event.keyCode), isRepeat: event.isARepeat,
                flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            ) {
                MainActor.assumeIsolated { self?.handleEscape() }
            }
            return event
        }
        isListening = true
        status = "正在监听 Fn / Esc；可切换到其他应用测试"
        return true
    }

    @MainActor
    private func handleEscape() {
        guard isListening else { return }
        status = "已收到 Esc；正在监听 Fn / Esc"
        onEscape?()
    }

    /// 仅独立 Esc 的首次按下触发；不把组合键或长按重复事件当成新的取消。
    static func isEscapePress(keyCode: Int64, isRepeat: Bool, flags: CGEventFlags) -> Bool {
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return keyCode == 53 && !isRepeat && flags.intersection(shortcutModifiers).isEmpty
    }

    func stop() {
        removeEventTap()

        // 只清理内部状态，停止监听不算作用户真实松开了 Fn。
        resetPendingFn()
        isListening = false
        status = "已停止监听"
        MainActor.assumeIsolated { onListeningStopped?() }
    }

    private func removeEventTap() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func resetPendingFn() {
        fnGesture.reset()
    }

    private func handleFlagsChanged(_ keyboardEvent: CGEvent) {
        guard let transition = fnGesture.flagsChanged(
            keyCode: keyboardEvent.getIntegerValueField(.keyboardEventKeycode),
            flags: keyboardEvent.flags
        ) else { return }
        let action: String
        switch transition {
        case .pressed: action = "Fn 按下"
        case .released(true): action = "Fn 松开（独立按键）"
        case .released(false): action = "Fn 松开（组合键，不触发）"
        }
        let event = FnKeyEvent(action: action, time: .now)
        events.insert(event, at: 0)
        events = Array(events.prefix(20))
        status = "已记录：\(event.action)"
        if transition == .released(trigger: true) {
            MainActor.assumeIsolated { onFnTap?() }
        }
    }
}

struct FnKeyEvent: Identifiable {
    let id = UUID()
    let action: String
    let time: Date
}
