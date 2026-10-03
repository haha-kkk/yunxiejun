import SwiftUI

struct TextCleanupView: View {
    @EnvironmentObject private var cleanup: TextCleanupController
    @EnvironmentObject private var recognition: SpeechRecognitionController
    @EnvironmentObject private var simulation: SessionValidationController
    @EnvironmentObject private var monitor: FnKeyMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("整理表达").font(.title).fontWeight(.semibold)
                Text("去掉多余口头语、修顺表达，保留原意。点击“整理文字”或“整理后输入”后，文字会发送给阿里百炼北京服务。")
                    .foregroundStyle(.secondary)
                Text("整理时会一并发送词典中的已确认词条作为拼写参考；词典修改从下一次整理生效。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("原始文字").font(.headline)
                    Spacer()
                    Button("带入最近一次转写") { cleanup.input = recognition.text }
                        .disabled(cleanup.isBusy || recognition.isBusy || recognition.text.isEmpty)
                    Button("清空") { cleanup.input = ""; cleanup.reset() }
                        .disabled(cleanup.isBusy || cleanup.input.isEmpty)
                }
                TextEditor(text: $cleanup.input)
                    .font(.body)
                    .frame(minHeight: 130)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    .disabled(cleanup.isBusy)
                    .accessibilityLabel("待整理文字")
                    .accessibilityIdentifier("cleanup-input")
                HStack {
                    Button("整理文字") { simulation.handleEscape(); cleanup.begin() }
                        .disabled(cleanup.isBusy || cleanup.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("整理后输入") { simulation.handleEscape(); cleanup.begin(outputToCursor: true) }
                        .disabled(cleanup.isBusy || cleanup.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消整理") { cleanup.cancelIfActive() }.disabled(!cleanup.isBusy)
                    if cleanup.isBusy { ProgressView().controlSize(.small) }
                }
                Text(cleanup.status).accessibilityIdentifier("cleanup-status")
                DisclosureGroup("本地输入测试（不调用 API）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("把上面的原文直接输入其他应用，用于单独检查光标位置和权限；不录音，不整理，不上传。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("5 秒后输入原文（本地测试）") {
                            simulation.handleEscape()
                            cleanup.begin(localOutputTest: true)
                        }.disabled(cleanup.isBusy || cleanup.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text("“整理后输入”会先留出 5 秒让你切换应用，再开始整理；整理完成时写入光标最终所在的位置。有选中文字时会替换该选区，请先确认光标。")
                    .font(.callout).foregroundStyle(.secondary)
                if !monitor.isListening {
                    Text("全局 Esc 尚未开启；可到 Fn 页开启监听，或返回本页点“取消整理”。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let outputStatus = cleanup.outputStatus {
                    Text(outputStatus).accessibilityIdentifier("text-output-status")
                }
                if let result = cleanup.result {
                    if !cleanup.isLocalOutputTest {
                        DisclosureGroup("本次参考词条（\(result.referenceTerms.count) 个）") {
                            Text(result.referenceTerms.isEmpty ? "本次使用空词典。" : result.referenceTerms.joined(separator: "、"))
                                .font(.callout).textSelection(.enabled)
                        }
                    }
                    Text(cleanup.isLocalOutputTest ? "本地测试文字（未整理）" : "整理结果").font(.headline)
                    Text(result.cleanedText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("cleanup-result")
                }
                Text("每次整理会使用 API 额度；取消后保留原文，不显示迟到结果。切页或关闭本工具窗口可取消等待；切换到其他应用不会取消。已发出的请求仍可能计费。只点“整理文字”不会向外输入；结果不会自动复制或保存到归档。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onExitCommand { cleanup.cancelIfActive() }
        .onDisappear { cleanup.cancelIfActive() }
    }
}
