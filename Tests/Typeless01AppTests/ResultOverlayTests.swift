import Foundation
import Testing
@testable import Typeless01App

@Suite("T24 完整结果浮窗与手动复制")
@MainActor
struct ResultOverlayTests {
    private func result(_ text: String = "请用 Claude 整理需求。\n先不要发布。") throws -> TextCleanupResult {
        try TextCleanupResult(request: TextCleanupRequest(originalText: text), output: text)
    }

    @Test("输出失败和输出超时显示完整结果，保留未确认写入警告", arguments: [false, true])
    func fallback(_ timedOut: Bool) throws {
        let model = ResultOverlayModel(writeClipboard: { _ in Issue.record("展示不得复制"); return false })
        let id = UUID(), result = try result()
        model.receive(state: .failed(id, reason: timedOut ? .timedOut : .outputFailed), result: result,
                      status: "无法确认写入，请先检查目标，避免重复输入。")
        #expect(model.content?.id == id && model.content?.text == result.cleanedText)
        #expect(model.content?.notice.contains("避免重复输入") == true)
        #expect(model.copyStatus.isEmpty)
    }

    @Test("成功、处理中、取消以及尚无整理结果的失败不显示复制浮窗")
    func hiddenStates() throws {
        let id = UUID(), result = try result()
        let states: [DictationSession.State] = [.idle, .recording(id), .processing(id), .ready(id, text: "结果"),
            .awaitingOutput(id, text: "结果"), .delivering(id), .cancelled(id), .completed(id, text: "结果"),
            .failed(id, reason: .recordingFailed), .failed(id, reason: .processingFailed), .failed(id, reason: .emptyResult)]
        let model = ResultOverlayModel()
        for state in states {
            model.receive(state: .failed(id, reason: .outputFailed), result: result, status: "失败")
            #expect(model.content != nil)
            model.receive(state: state, result: result, status: "")
            #expect(model.content == nil)
        }
        model.receive(state: .failed(id, reason: .timedOut), result: nil, status: "识别超时")
        #expect(model.content == nil)
    }

    @Test("关闭不复制，重复通知不重开，下一轮结果正常显示")
    func dismissalAndNewSession() throws {
        var clipboard = "原剪贴板标记"
        let model = ResultOverlayModel(writeClipboard: { clipboard = $0; return true })
        let id = UUID(), next = UUID(), result = try result()
        model.receive(state: .failed(id, reason: .outputFailed), result: result, status: "失败")
        model.dismiss(); model.dismiss()
        model.receive(state: .failed(id, reason: .outputFailed), result: result, status: "重复通知")
        #expect(model.content == nil && clipboard == "原剪贴板标记")
        model.copy()
        #expect(clipboard == "原剪贴板标记")
        model.receive(state: .recording(next), result: nil, status: "录音中")
        model.receive(state: .failed(next, reason: .outputFailed), result: result, status: "失败")
        #expect(model.content?.id == next && model.copyStatus.isEmpty)
    }

    @Test("只有点击复制才写剪贴板，长文本、换行和 Unicode 保留完整")
    func explicitCopy() throws {
        var writes: [String] = []
        let model = ResultOverlayModel(writeClipboard: { writes.append($0); return true })
        let id = UUID(), text = String(repeating: "Claude：不要发布 👩🏽‍💻。\n", count: 200) + "最后一行。"
        let result = try result(text)
        model.receive(state: .failed(id, reason: .outputFailed), result: result, status: "失败")
        #expect(writes.isEmpty && model.content?.text == text)
        model.copy()
        #expect(writes == [text] && model.copyStatus == "已复制")
        model.receive(state: .failed(id, reason: .outputFailed), result: result, status: "失败")
        #expect(model.copyStatus == "已复制" && writes.count == 1)
        model.dismiss()
        #expect(writes.count == 1)
    }

    @Test("复制失败不冒充成功，用户再次点击才重试，下一轮清除复制状态")
    func copyFailureAndReset() throws {
        var attempts = 0
        let model = ResultOverlayModel(writeClipboard: { _ in attempts += 1; return attempts > 1 })
        model.receive(state: .failed(UUID(), reason: .outputFailed), result: try result(), status: "失败")
        model.copy()
        #expect(model.copyStatus.contains("复制失败") && attempts == 1)
        model.copy()
        #expect(model.copyStatus == "已复制" && attempts == 2)
        model.receive(state: .recording(UUID()), result: nil, status: "录音中")
        #expect(model.content == nil && model.copyStatus.isEmpty)
    }
}
