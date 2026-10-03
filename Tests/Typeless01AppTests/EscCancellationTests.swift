import CoreGraphics
import Testing
@testable import Typeless01App

@Suite("T06 Esc 取消会话")
@MainActor
struct EscCancellationTests {
    @Test("只识别独立 Esc 首次按下，不处理其他键、重复或组合键")
    func escapeFiltering() {
        #expect(FnKeyMonitor.isEscapePress(keyCode: 53, isRepeat: false, flags: []))
        #expect(!FnKeyMonitor.isEscapePress(keyCode: 0, isRepeat: false, flags: []))
        #expect(!FnKeyMonitor.isEscapePress(keyCode: 53, isRepeat: true, flags: []))
        for modifier in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            #expect(!FnKeyMonitor.isEscapePress(keyCode: 53, isRepeat: false, flags: modifier))
        }
    }

    @Test("空闲时 Esc 无效，不产生会话或输出")
    func idleEscape() {
        let controller = SessionValidationController()
        #expect(!controller.handleEscape())
        #expect(controller.state == .idle)
        #expect(controller.outputText == nil)
        #expect(!controller.canSimulateResult)
    }

    @Test("模拟录音中 Esc 取消，随后返回的结果被拦截")
    func cancelRecording() {
        let controller = SessionValidationController()
        controller.startRecording()
        #expect(controller.isRecording)
        #expect(controller.handleEscape())
        #expect(controller.stateTitle == "已取消")
        controller.simulateResult()
        #expect(controller.resultNotice == "结果已拦截，未产生输出")
        #expect(controller.outputText == nil)
    }

    @Test("模拟处理中 Esc 取消，Thinking 条件消失且迟到结果无输出")
    func cancelProcessing() {
        let controller = SessionValidationController()
        controller.startRecording()
        controller.finishRecording()
        #expect(controller.isProcessing)
        #expect(controller.handleEscape())
        #expect(!controller.isProcessing)
        #expect(controller.stateTitle == "已取消")
        controller.simulateResult()
        #expect(controller.resultNotice == "结果已拦截，未产生输出")
        #expect(controller.outputText == nil)
    }

    @Test("重复 Esc 不改变已取消状态，不产生输出")
    func repeatedEscape() {
        let controller = SessionValidationController()
        controller.startRecording()
        controller.handleEscape()
        let state = controller.state
        #expect(!controller.handleEscape())
        #expect(controller.state == state)
        #expect(controller.outputText == nil)
    }

    @Test("模拟结果正常完成后 Esc 不撤销已交付结果")
    func completedEscape() {
        let controller = SessionValidationController()
        controller.startRecording()
        controller.finishRecording()
        controller.simulateResult()
        #expect(controller.outputText != nil)
        let before = controller.state
        let output = controller.outputText
        #expect(!controller.handleEscape())
        #expect(controller.state == before)
        #expect(controller.outputText == output)
    }

    @Test("取消后能重新模拟，旧的拦截提示不会污染新一轮")
    func restartAfterCancellation() {
        let controller = SessionValidationController()
        controller.startRecording()
        let first = controller.state
        controller.handleEscape()
        controller.simulateResult()
        controller.startRecording()
        #expect(controller.isRecording)
        #expect(controller.state != first)
        #expect(controller.resultNotice == "尚未模拟结果返回")
        controller.finishRecording()
        controller.simulateResult()
        #expect(controller.stateTitle == "模拟完成")
        #expect(controller.outputText != nil)
    }

    @Test("忙碌时重复开始、过早提交结果不会破坏当前模拟会话")
    func rejectInvalidSimulationActions() {
        let controller = SessionValidationController()
        controller.startRecording()
        let before = controller.state
        controller.startRecording()
        controller.simulateResult()
        #expect(controller.state == before)
        #expect(controller.outputText == nil)
        #expect(controller.handleEscape())
    }
}
