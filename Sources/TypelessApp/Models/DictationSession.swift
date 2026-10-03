import Foundation

/// 只管理会话规则，不操作麦克风、网络、窗口或剪贴板。
/// 后续异步结果须回到主线程，并携带开始时取得的编号提交。
@MainActor
final class DictationSession {
    enum Failure: Equatable {
        case emptyResult
        case recordingFailed
        case processingFailed
        case timedOut
        case outputFailed
    }

    enum State: Equatable {
        case idle
        case recording(UUID)
        case processing(UUID)
        case ready(UUID, text: String)
        case awaitingOutput(UUID, text: String)
        case delivering(UUID)
        case cancelled(UUID)
        case failed(UUID, reason: Failure)
        case completed(UUID, text: String)
    }

    private(set) var state: State = .idle

    /// 一次只处理一个会话；取消或完成后可以开始下一次。
    @discardableResult
    func start() -> UUID? {
        switch state {
        case .recording, .processing, .ready, .awaitingOutput, .delivering:
            return nil
        case .idle, .cancelled, .failed, .completed:
            let id = UUID()
            state = .recording(id)
            return id
        }
    }

    @discardableResult
    func finishRecording(for sessionID: UUID) -> Bool {
        guard case .recording(let id) = state, id == sessionID else { return false }
        state = .processing(id)
        return true
    }

    @discardableResult
    func cancel(for sessionID: UUID) -> Bool {
        switch state {
        case .recording(let id), .processing(let id), .ready(let id, _), .awaitingOutput(let id, _):
            guard id == sessionID else { return false }
            state = .cancelled(id)
            return true
        case .idle, .cancelled, .failed, .delivering, .completed:
            return false
        }
    }

    /// 录音错误、服务错误或超时由调用方报告；本模型不自行决定超时时长。
    @discardableResult
    func fail(_ reason: Failure, for sessionID: UUID) -> Bool {
        switch state {
        case .recording(let id), .processing(let id), .ready(let id, _), .awaitingOutput(let id, _):
            guard id == sessionID else { return false }
            state = .failed(id, reason: reason)
            return true
        case .idle, .cancelled, .failed, .delivering, .completed:
            return false
        }
    }

    /// true 仅表示结果已就绪，交付前仍可取消。空白结果进入失败状态。
    @discardableResult
    func complete(text: String, for sessionID: UUID) -> Bool {
        guard case .processing(let currentID) = state,
              currentID == sessionID else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(currentID, reason: .emptyResult)
            return false
        }
        // 只用去空白后的内容判断是否为空，保留有效原文的空格和换行。
        state = .ready(currentID, text: text)
        return true
    }

    /// 实际跨应用输出会异步核对焦点，不能塞进旧的同步 deliver 闭包。
    /// 等待期间允许取消；调用者同时取消输出 Task，输出器在系统写入前再检查取消。
    func beginOutput(for sessionID: UUID) -> String? {
        guard case .ready(let id, let text) = state, id == sessionID else { return nil }
        state = .awaitingOutput(id, text: text)
        return text
    }

    @discardableResult
    func finishOutput(for sessionID: UUID) -> Bool {
        guard case .awaitingOutput(let id, let text) = state, id == sessionID else { return false }
        state = .completed(id, text: text)
        return true
    }

    /// 所有异步准备须在调用前完成；真正交付必须在此同步闭包内执行。
    /// 不可在闭包中另起 Task 或排队延迟输出，否则会绕过取消检查。
    /// 主线程上检查状态后立即交付，不留下 await 间隙；交付中拒绝重入操作。
    /// 此入口不实现真实输出，也无法撤回交付闭包已经产生的外部副作用。
    @discardableResult
    func deliver(for sessionID: UUID, using output: @MainActor (String) throws -> Void) -> Bool {
        guard case .ready(let id, let text) = state, id == sessionID else { return false }
        state = .delivering(id)
        do {
            try output(text)
        } catch {
            state = .failed(id, reason: .outputFailed)
            return false
        }
        state = .completed(id, text: text)
        return true
    }
}
