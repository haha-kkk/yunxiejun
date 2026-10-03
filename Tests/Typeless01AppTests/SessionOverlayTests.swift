import Foundation
import Testing
@testable import Typeless01App

@Suite("T07 状态浮窗与 Fn 切换")
@MainActor
struct SessionOverlayTests {
    @Test("Fn 先开始录音再进入处理，处理期间重复 Fn 不改变会话")
    func fnSequence() {
        let controller = SessionValidationController()
        controller.handleFn()
        guard case .recording(let id) = controller.state else {
            Issue.record("首次 Fn 应开始模拟录音")
            return
        }
        #expect(SessionOverlayPhase(state: controller.state) == .recording)
        controller.handleFn()
        #expect(controller.state == .processing(id))
        #expect(SessionOverlayPhase(state: controller.state) == .processing)
        controller.handleFn()
        #expect(controller.state == .processing(id))
    }

    @Test("录音和处理中 Esc 都隐藏浮窗，迟到结果不能重新显示")
    func cancellationHidesOverlay() {
        for finishRecording in [false, true] {
            let controller = SessionValidationController()
            controller.handleFn()
            if finishRecording { controller.handleFn() }
            #expect(controller.handleEscape())
            #expect(SessionOverlayPhase(state: controller.state) == nil)
            controller.simulateResult()
            #expect(SessionOverlayPhase(state: controller.state) == nil)
            #expect(controller.outputText == nil)
            controller.handleFn()
            #expect(SessionOverlayPhase(state: controller.state) == .recording)
        }
    }

    @Test("完成后隐藏浮窗，下一次 Fn 能开始新会话")
    func completedThenRestart() {
        let controller = SessionValidationController()
        controller.handleFn()
        controller.handleFn()
        controller.simulateResult()
        #expect(controller.stateTitle == "模拟完成")
        #expect(SessionOverlayPhase(state: controller.state) == nil)
        controller.handleFn()
        #expect(SessionOverlayPhase(state: controller.state) == .recording)
        #expect(controller.outputText == nil)
    }

    @Test("空闲、失败、取消、待交付、交付中和完成都不显示录音或处理浮窗")
    func hiddenStates() {
        let id = UUID()
        let states: [DictationSession.State] = [
            .idle, .failed(id, reason: .timedOut), .cancelled(id),
            .ready(id, text: "测试"), .delivering(id), .completed(id, text: "测试")
        ]
        for state in states {
            #expect(SessionOverlayPhase(state: state) == nil)
        }
    }
}
