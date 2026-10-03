import AppKit
import SwiftUI

struct DictationView: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var monitor: FnKeyMonitor
    @EnvironmentObject private var archive: TranscriptArchiveController
    @State private var copyStatus = ""
    @AppStorage("clipboardCompatibilityInput") private var compatibilityInput = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("语音输入").font(.title).bold()
                    Spacer()
                    Button("打开归档") { archive.openWindow() }
                }
                if let error = archive.saveError {
                    Text(error).foregroundStyle(.red)
                    Button("重试保存") { archive.retrySaving() }.disabled(archive.isSaving)
                }
                Text("点击目标输入框，按 Fn 开始说话，再按 Fn 结束。随后自动识别、整理，并输入处理完成时的光标位置。Esc 取消。")
                Text("结束录音后，音频、转写及已确认词条会用于已配置的阿里百炼北京 API，并使用 API 额度。当前每段最多 3 分钟，到时自动结束；这不是原来的五秒录音测试。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(monitor.isListening ? "停止 Fn 监听" : "开启 Fn 监听") {
                        if monitor.isListening { monitor.stop() } else { monitor.start() }
                    }
                    Text(monitor.status).font(.callout)
                }
                Toggle("兼容输入（临时使用剪贴板）", isOn: $compatibilityInput)
                    .disabled(dictation.isBusy)
                Text("兼容模式直接发送一次粘贴，不自动发送消息；随后恢复原剪贴板，期间其他应用更新的剪贴板不覆盖。关闭后使用原辅助功能写入方式。无法确认成功时不再次写入，请先检查目标。")
                    .font(.caption).foregroundStyle(.secondary)
                FnShortcutHelpView()
                Divider()
                Text(dictation.status).font(.headline).accessibilityIdentifier("dictation-status")
                if let notice = dictation.notice { Text(notice).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button(dictation.isRecording ? "结束录音" : "开始录音") { dictation.handleFn() }
                        .disabled(dictation.isBusy && !dictation.isRecording)
                    Button("取消本次") { dictation.cancel() }.disabled(!dictation.isBusy)
                }
                Text("这两个录音按钮也走真实流程，方便检查麦克风；向其他应用输入时请使用 Fn，以保留外部光标。关闭主窗口不会中断真实录音；菜单栏可重新打开。")
                    .font(.callout).foregroundStyle(.secondary)
                if !dictation.transcript.isEmpty {
                    DisclosureGroup("本次原始转写") { Text(dictation.transcript).textSelection(.enabled) }
                }
                if let result = dictation.result {
                    Text("本次整理结果").font(.headline)
                    Text(result.cleanedText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("dictation-result")
                    Button("复制结果") {
                        NSPasteboard.general.clearContents()
                        copyStatus = NSPasteboard.general.setString(result.cleanedText, forType: .string)
                            ? "已复制。" : "复制失败，请重新点击。"
                    }.disabled(dictation.isBusy)
                    if !copyStatus.isEmpty { Text(copyStatus).font(.callout) }
                    Text("本次参考词条：\(result.referenceTerms.isEmpty ? "无" : result.referenceTerms.joined(separator: "、"))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("没有可用输入框或无法确认写入时，会弹出“复制最后的转录”，本页也保留完整结果。只有点击复制按钮才写入剪贴板。浮窗显示 10 分钟，关闭后的已保存结果可在归档中找回。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("成功输入后，会在本机观察原输入框最多 60 秒。直接改正一个术语后停留两秒，三次独立纠正后会询问是否加入词典；切换应用或输入框、Esc、下次录音会停止本轮观察。输入框不支持读取时不会自动学习。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onChange(of: dictation.result) { _, _ in copyStatus = "" }
        .onExitCommand { dictation.cancel() }
    }
}
