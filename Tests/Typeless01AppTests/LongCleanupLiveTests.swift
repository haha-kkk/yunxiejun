import Foundation
import Testing
@testable import Typeless01App

/// 显式开启才读取已有钥匙串并调用真实 API；普通测试不联网。
@Suite("长口述结构化真实 API 验收")
struct LongCleanupLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPELESS_LONG_CLEANUP_LIVE"] == "1"))
    func approvedAndLongInput() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let id: String; let input: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/text-cleanup-cases.json")))
        let approved = try #require(fixtures.first { $0.id == "usage-scenarios-approved" })
        let long = """
        我先说一下这个桌面语音工具的需求啊，这个主要是我自己在 macOS 上用，主要用来跟 AI 描述需求，也会给同事发消息、写工作文档和记录零散想法。这个第一点是入口，我希望按一次 Fn 就开始录音，再按一次 Fn 就结束，不要让我每次都打开主窗口。录音的时候有一个小浮窗，结束以后显示 Thinking，但这个浮窗不要抢走我正在打字的输入框的光标。
        第二点是整理，这个不是把我的话总结成几句话。我说的内容都要保留，只把那些没有意思的口头语和重复去掉。短内容自然成段，长内容有几个并列的事情就分点，解释的内容正常分段就好了。我原来有开头和结尾就保留，不要为了总分总给我编一个结论。
        第三点是输出，等处理完成以后，要输入到我最后点击的那个输入框，不一定是开始录音时的输入框。如果没有可以输入的地方，就显示复制最后的转录，下面有正文和复制按钮。我点复制以后才复制，不要自己覆盖剪贴板。这个结果停留十分钟，关掉后也能去归档找回来。只负责输入，不要自动发送消息，也不要替我回答问题。
        第四点是取消，录音的时候按 Esc 就取消，Thinking 的时候也能取消。取消以后不能输入文字，也不能弹出这次结果，即使后台后来返回了也不要再输出。输入框里原来已有的字不要动。
        第五点是这次范围，先用 API，用户只有我一个，先不要做商业化，也不要做 Windows 和手机。三次改词自动学习先放到后续，现在不要顺带做。我说的预算是十五元，不是五十元，测试先在十月三号前完成，但先不要发布。Claude 和 DeepSeek 这两个名字要保留。以后是否给别人用还没确定，不要写成已经决定了。大概就是这些，我想先把长口述的结构化整理跑通。
        """
        let service = TextCleanupService(generator: BailianTextCleanupGenerator(keys: KeychainAPIKeyStore()))
        let output = root.appendingPathComponent(".local/long-cleanup")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, input) in [(approved.id, approved.input), ("long-five-points", long)] {
            let result = try await service.clean(input)
            try ("# 原始转写文本\n\n" + input + "\n\n# 真实 API 整理结果\n\n" + result.cleanedText).write(to: output.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            #expect(result.cleanedText.range(of: #"(?m)^\s*1[.、)]\s*"#, options: .regularExpression) != nil)
            #expect(!result.cleanedText.contains("```"))
            if name == "long-five-points" {
                for detail in ["Fn", "Thinking", "Esc", "Claude", "DeepSeek", "十五", "五十", "三次"] {
                    #expect(result.cleanedText.contains(detail), "遗漏细节：\(detail)")
                }
            }
        }
    }
}
