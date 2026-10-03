import Foundation
import Testing
@testable import Typeless01App

@Suite("T05 语音会话状态模型")
@MainActor
struct DictationSessionTests {
    @Test("初始为空闲；开始后进入录音中")
    func startRecording() throws {
        let session = DictationSession()
        #expect(session.state == .idle)
        let id = try #require(session.start())
        #expect(session.state == .recording(id))
    }

    @Test("录音结束后进入处理中，保留会话编号")
    func finishRecording() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.finishRecording(for: id))
        #expect(session.state == .processing(id))
    }

    @Test("录音中取消；迟到结果被拒绝")
    func cancelRecording() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.cancel(for: id))
        #expect(session.state == .cancelled(id))
        #expect(!session.complete(text: "不应出现的文字", for: id))
        #expect(session.state == .cancelled(id))
    }

    @Test("处理中取消；迟到结果被拒绝")
    func cancelProcessing() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.finishRecording(for: id))
        #expect(session.cancel(for: id))
        #expect(session.state == .cancelled(id))
        #expect(!session.complete(text: "不应出现的文字", for: id))
        #expect(session.state == .cancelled(id))
    }

    @Test("结果就绪后交付；保留完整文字且只接收一次")
    func completeOnce() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.finishRecording(for: id))
        let text = "请帮我整理 Claude 的需求。\n保留第二点。"
        #expect(session.complete(text: text, for: id))
        #expect(session.state == .ready(id, text: text))
        var delivered: [String] = []
        #expect(session.deliver(for: id) { delivered.append($0) })
        #expect(delivered == [text])
        #expect(!session.deliver(for: id) { delivered.append($0) })
        #expect(delivered == [text])
        #expect(session.state == .completed(id, text: text))
        #expect(!session.complete(text: "重复回调", for: id))
        #expect(!session.cancel(for: id))
        #expect(!session.finishRecording(for: id))
        #expect(session.state == .completed(id, text: text))
    }

    @Test("取消后重新开始；上一轮结果不能污染新一轮")
    func rejectPreviousSession() throws {
        let session = DictationSession()
        let oldID = try #require(session.start())
        #expect(session.finishRecording(for: oldID))
        #expect(session.cancel(for: oldID))
        let newID = try #require(session.start())
        #expect(newID != oldID)
        #expect(!session.complete(text: "旧结果", for: oldID))
        #expect(session.state == .recording(newID))
        #expect(session.finishRecording(for: newID))
        #expect(!session.complete(text: "旧结果", for: oldID))
        #expect(session.state == .processing(newID))
        #expect(session.complete(text: "新结果", for: newID))
        #expect(session.state == .ready(newID, text: "新结果"))
    }

    @Test("完成后可重新开始，并使用新编号")
    func restartAfterCompletion() throws {
        let session = DictationSession()
        let firstID = try #require(session.start())
        #expect(session.finishRecording(for: firstID))
        #expect(session.complete(text: "第一轮", for: firstID))
        #expect(session.deliver(for: firstID) { _ in })
        let nextID = try #require(session.start())
        #expect(nextID != firstID)
        #expect(session.state == .recording(nextID))
    }

    @Test("空闲时结束、取消或提交结果均无效")
    func rejectIdleActions() {
        let session = DictationSession()
        let id = UUID()
        #expect(!session.finishRecording(for: id))
        #expect(!session.cancel(for: id))
        #expect(!session.complete(text: "无会话结果", for: UUID()))
        #expect(session.state == .idle)
    }

    @Test("忙碌时重复开始或结束不覆盖当前会话")
    func rejectDuplicateActions() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.start() == nil)
        #expect(!session.complete(text: "过早结果", for: id))
        #expect(session.state == .recording(id))
        #expect(session.finishRecording(for: id))
        #expect(session.start() == nil)
        #expect(!session.finishRecording(for: id))
        #expect(session.state == .processing(id))
        #expect(session.cancel(for: id))
        #expect(!session.cancel(for: id))
        #expect(!session.finishRecording(for: id))
        #expect(session.state == .cancelled(id))
    }

    @Test("处理中拒绝不匹配的编号，仍可接收正确结果")
    func rejectUnknownSession() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        #expect(session.finishRecording(for: id))
        #expect(!session.complete(text: "错误编号", for: UUID()))
        #expect(session.state == .processing(id))
        #expect(session.complete(text: "正确编号", for: id))
        #expect(session.state == .ready(id, text: "正确编号"))
    }

    @Test("空字符串和各类纯空白进入失败，不能交付且可重开")
    func rejectBlankResults() throws {
        for text in ["", " ", "\n\r\t", "\u{00A0}\u{3000}"] {
            let session = DictationSession()
            let id = try #require(session.start())
            #expect(session.finishRecording(for: id))
            #expect(!session.complete(text: text, for: id))
            #expect(session.state == .failed(id, reason: .emptyResult))
            var calls = 0
            #expect(!session.deliver(for: id) { _ in calls += 1 })
            #expect(calls == 0)
            #expect(session.start() != nil)
        }
    }

    @Test("有效文字的首尾空格、换行和表情保持原样")
    func preserveValidText() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        let text = "  中文🙂\n第二行\t "
        #expect(session.complete(text: text, for: id))
        var delivered: String?
        #expect(session.deliver(for: id) { delivered = $0 })
        #expect(delivered == text)
    }

    @Test("录音或处理报错后进入失败，允许重新开始")
    func failAndRestart() throws {
        for reason in [DictationSession.Failure.recordingFailed, .processingFailed] {
            let session = DictationSession()
            let id = try #require(session.start())
            if reason == .processingFailed { session.finishRecording(for: id) }
            #expect(session.fail(reason, for: id))
            #expect(session.state == .failed(id, reason: reason))
            #expect(!session.complete(text: "失败后的结果", for: id))
            #expect(!session.fail(.timedOut, for: id))
            #expect(!session.cancel(for: id))
            #expect(session.state == .failed(id, reason: reason))
            let next = try #require(session.start())
            #expect(next != id)
            #expect(session.state == .recording(next))
        }
    }

    @Test("收到超时通知后退出处理中，迟到结果不能交付")
    func timeoutRejectsLateResult() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        #expect(session.fail(.timedOut, for: id))
        #expect(!session.complete(text: "迟到结果", for: id))
        var calls = 0
        #expect(!session.deliver(for: id) { _ in calls += 1 })
        #expect(calls == 0)
        #expect(session.state == .failed(id, reason: .timedOut))
        #expect(session.start() != nil)
    }

    @Test("旧编号的结束、取消、失败及交付不能影响新会话")
    func rejectStaleActions() throws {
        let session = DictationSession()
        let old = try #require(session.start())
        session.cancel(for: old)
        let current = try #require(session.start())
        for phase in 0..<3 {
            if phase == 1 { session.finishRecording(for: current) }
            if phase == 2 { session.complete(text: "新会话", for: current) }
            let before = session.state
            #expect(!session.finishRecording(for: old))
            #expect(!session.cancel(for: old))
            #expect(!session.fail(.timedOut, for: old))
            #expect(!session.complete(text: "", for: old))
            var calls = 0
            #expect(!session.deliver(for: old) { _ in calls += 1 })
            #expect(calls == 0)
            #expect(session.state == before)
        }
    }

    @Test("结果已返回但尚未交付时取消，输出闭包一次也不执行")
    func cancelReadyResult() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        session.complete(text: "不应交付的文字", for: id)
        #expect(session.cancel(for: id))
        var delivered: [String] = []
        #expect(!session.deliver(for: id) { delivered.append($0) })
        #expect(delivered.isEmpty)
        #expect(session.state == .cancelled(id))
        let next = try #require(session.start())
        session.finishRecording(for: next)
        session.complete(text: "下一轮", for: next)
        #expect(!session.deliver(for: id) { delivered.append($0) })
        #expect(session.deliver(for: next) { delivered.append($0) })
        #expect(delivered == ["下一轮"])
    }

    @Test("空闲、录音中、处理中及错误编号均不可交付")
    func rejectPrematureDelivery() throws {
        let session = DictationSession()
        var calls = 0
        #expect(!session.fail(.timedOut, for: UUID()))
        #expect(!session.deliver(for: UUID()) { _ in calls += 1 })
        let id = try #require(session.start())
        #expect(!session.deliver(for: id) { _ in calls += 1 })
        session.finishRecording(for: id)
        #expect(!session.deliver(for: id) { _ in calls += 1 })
        session.complete(text: "当前结果", for: id)
        #expect(!session.deliver(for: UUID()) { _ in calls += 1 })
        #expect(calls == 0)
        #expect(session.state == .ready(id, text: "当前结果"))
    }

    @Test("待交付时拒绝重复结果和重开，失败可清除待交付文字")
    func protectReadyResult() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        session.complete(text: "原结果", for: id)
        #expect(session.start() == nil)
        #expect(!session.finishRecording(for: id))
        #expect(!session.complete(text: "覆盖内容", for: id))
        #expect(!session.complete(text: "", for: id))
        #expect(session.state == .ready(id, text: "原结果"))
        #expect(session.fail(.processingFailed, for: id))
        #expect(session.state == .failed(id, reason: .processingFailed))
        var calls = 0
        #expect(!session.deliver(for: id) { _ in calls += 1 })
        #expect(calls == 0)
    }

    @Test("交付抛错时记录失败，不冒充已完成，可重新开始")
    func outputFailure() throws {
        enum OutputError: Error { case unavailable }
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        session.complete(text: "文字", for: id)
        var calls = 0
        #expect(!session.deliver(for: id) { _ in
            calls += 1
            throw OutputError.unavailable
        })
        #expect(session.state == .failed(id, reason: .outputFailed))
        #expect(!session.deliver(for: id) { _ in calls += 1 })
        #expect(calls == 1)
        #expect(session.start() != nil)
    }

    @Test("同步交付期间拒绝重入，完成后拒绝迟到失败通知")
    func rejectReentrantDelivery() throws {
        let session = DictationSession()
        let id = try #require(session.start())
        session.finishRecording(for: id)
        session.complete(text: "文字", for: id)
        var calls = 0
        let delivered = session.deliver(for: id) { _ in
            calls += 1
            #expect(session.state == .delivering(id))
            #expect(session.start() == nil)
            #expect(!session.cancel(for: id))
            #expect(!session.fail(.timedOut, for: id))
            #expect(!session.finishRecording(for: id))
            #expect(!session.complete(text: "覆盖", for: id))
            #expect(!session.deliver(for: id) { _ in calls += 1 })
        }
        #expect(delivered)
        #expect(calls == 1)
        #expect(!session.fail(.timedOut, for: id))
        #expect(session.state == .completed(id, text: "文字"))
    }
}
