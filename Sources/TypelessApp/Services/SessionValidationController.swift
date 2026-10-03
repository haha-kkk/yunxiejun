import Combine
import Foundation

/// T06/T07 的模拟入口：使用真实会话模型，但不录音、不联网、不向外部应用输出。
@MainActor
final class SessionValidationController: ObservableObject {
    @Published private(set) var state: DictationSession.State = .idle
    @Published private(set) var outputText: String?
    @Published private(set) var resultNotice = "尚未模拟结果返回"

    private let session = DictationSession()
    private var lastSessionID: UUID?

    var canStart: Bool {
        switch state {
        case .idle, .cancelled, .failed, .completed: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }

    var canSimulateResult: Bool { lastSessionID != nil }

    var stateTitle: String {
        switch state {
        case .idle: return "空闲"
        case .recording: return "模拟录音中"
        case .processing: return "模拟处理中"
        case .ready: return "待交付"
        case .awaitingOutput: return "等待输入"
        case .delivering: return "交付中"
        case .cancelled: return "已取消"
        case .failed: return "已失败"
        case .completed: return "模拟完成"
        }
    }

    func startRecording() {
        guard let id = session.start() else { return }
        lastSessionID = id
        outputText = nil
        resultNotice = "尚未模拟结果返回"
        state = session.state
    }

    func finishRecording() {
        guard case .recording(let id) = state else { return }
        session.finishRecording(for: id)
        state = session.state
    }

    func handleFn() {
        if canStart {
            startRecording()
        } else if isRecording {
            finishRecording()
        }
        // 处理中再次按 Fn 不新开会话，也不跳过处理；仍可用 Esc 取消。
    }

    func handleSystemInterruption() {
        if handleEscape() {
            resultNotice = "系统休眠或用户会话切换，本次会话已取消；按 Fn 可重新开始"
        }
    }

    @discardableResult
    func handleEscape() -> Bool {
        let id: UUID
        switch session.state {
        case .recording(let current), .processing(let current), .ready(let current, _):
            id = current
        default:
            return false
        }
        guard session.cancel(for: id) else { return false }
        outputText = nil
        state = session.state
        return true
    }

    func simulateResult() {
        guard let id = lastSessionID else { return }
        let accepted = session.complete(text: "这是一条模拟结果，不会输入其他应用。", for: id)
        let delivered = accepted && session.deliver(for: id) { outputText = $0 }
        resultNotice = delivered ? "模拟结果已接收" : "结果已拦截，未产生输出"
        state = session.state
    }
}
