import AppKit
import Testing
@testable import Typeless01App

@Suite("T07 Fn 组合键保护")
struct FnGestureTests {
    @Test("独立 Fn 只在松开时触发；长按重复状态不触发")
    func standaloneRelease() {
        var gesture = FnGesture()
        #expect(gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn) == .pressed)
        #expect(gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn) == nil)
        #expect(gesture.flagsChanged(keyCode: 63, flags: []) == .released(trigger: true))
        #expect(gesture.flagsChanged(keyCode: 63, flags: []) == nil)
    }

    @Test("先按修饰键再 Fn 不触发，提前松开修饰键也不能变成独立 Fn")
    func modifierFirst() {
        for modifier in [CGEventFlags.maskShift, .maskCommand, .maskControl, .maskAlternate] {
            var gesture = FnGesture()
            _ = gesture.flagsChanged(keyCode: 63, flags: [.maskSecondaryFn, modifier])
            _ = gesture.flagsChanged(keyCode: 56, flags: .maskSecondaryFn)
            #expect(gesture.flagsChanged(keyCode: 63, flags: []) == .released(trigger: false))
        }
    }

    @Test("先 Fn 再修饰键不触发，两种松开顺序都不触发")
    func fnFirstModifier() {
        for releaseModifierFirst in [true, false] {
            var gesture = FnGesture()
            _ = gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn)
            _ = gesture.flagsChanged(keyCode: 56, flags: [.maskSecondaryFn, .maskShift])
            if releaseModifierFirst { _ = gesture.flagsChanged(keyCode: 56, flags: .maskSecondaryFn) }
            #expect(gesture.flagsChanged(keyCode: 63, flags: releaseModifierFirst ? [] : .maskShift)
                == .released(trigger: false))
        }
    }

    @Test("Fn 配普通键或方向键不触发，普通键先按住也不触发")
    func otherKeys() {
        for key: Int64 in [0, 123, 96] {
            for otherKeyFirst in [true, false] {
                var gesture = FnGesture()
                if otherKeyFirst { gesture.keyDown(key) }
                _ = gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn)
                gesture.keyDown(key)
                gesture.keyUp(key)
                #expect(gesture.flagsChanged(keyCode: 63, flags: []) == .released(trigger: false))
            }
        }
    }

    @Test("其他键的 secondaryFn 标记不能冒充实体 Fn")
    func unrelatedFlags() {
        var gesture = FnGesture()
        #expect(gesture.flagsChanged(keyCode: 123, flags: .maskSecondaryFn) == nil)
        #expect(gesture.flagsChanged(keyCode: 56, flags: []) == nil)
        #expect(gesture.flagsChanged(keyCode: 63, flags: []) == nil)
    }

    @Test("监听中断清空未完成手势，旧 Fn 松开无效，新一轮正常")
    func interruptedGesture() {
        var gesture = FnGesture()
        _ = gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn)
        gesture.reset()
        #expect(gesture.flagsChanged(keyCode: 63, flags: []) == nil)
        _ = gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn)
        #expect(gesture.flagsChanged(keyCode: 63, flags: []) == .released(trigger: true))
    }

    @Test("Fn 按住期间 Esc 取消，松开 Fn 不会重开")
    @MainActor
    func escapeWhileHoldingFn() {
        let session = SessionValidationController()
        session.handleFn()
        var gesture = FnGesture()
        _ = gesture.flagsChanged(keyCode: 63, flags: .maskSecondaryFn)
        gesture.keyDown(53)
        session.handleEscape()
        gesture.keyUp(53)
        let release = gesture.flagsChanged(keyCode: 63, flags: [])
        if release == .released(trigger: true) { session.handleFn() }
        #expect(session.stateTitle == "已取消")
        #expect(SessionOverlayPhase(state: session.state) == nil)
    }
}

@Suite("T07 系统中断保护")
@MainActor
struct SessionInterruptionTests {
    @Test("实际订阅的睡眠和唤醒通知取消录音/处理，迟到结果被拒绝，之后可重开")
    func notificationsCancel() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            for processing in [false, true] {
                let center = NotificationCenter()
                let session = SessionValidationController()
                let monitor = FnKeyMonitor()
                let observer = SessionInterruptionMonitor(session: session, keyboard: monitor, center: center)
                withExtendedLifetime(observer) {
                    session.handleFn()
                    if processing { session.handleFn() }
                    center.post(name: name, object: nil)
                    #expect(session.stateTitle == "已取消")
                    #expect(SessionOverlayPhase(state: session.state) == nil)
                    session.simulateResult()
                    #expect(session.outputText == nil)
                    session.handleFn()
                    #expect(session.isRecording)
                }
            }
        }
    }

    @Test("空闲和已完成结果不受系统中断影响，释放观察器后不再响应通知")
    func terminalStatesAndCleanup() {
        let center = NotificationCenter()
        let session = SessionValidationController()
        let monitor = FnKeyMonitor()
        var observer: SessionInterruptionMonitor? = SessionInterruptionMonitor(
            session: session, keyboard: monitor, center: center)
        withExtendedLifetime(observer) {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(session.state == .idle)
            session.handleFn()
            session.handleFn()
            session.simulateResult()
            let state = session.state
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(session.state == state)
        }
        observer = nil
        session.handleFn()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(session.isRecording)
    }
}
