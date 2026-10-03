import SwiftUI

struct MicrophoneRecordingView: View {
    @EnvironmentObject private var recording: MicrophoneRecordingController
    @EnvironmentObject private var simulation: SessionValidationController
    @EnvironmentObject private var recognition: SpeechRecognitionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("麦克风录音与识别").font(.title).fontWeight(.semibold)
                Text("这是独立的五秒录音测试，可回放确认；点击“识别这段录音”后发送到阿里百炼北京服务。完整 Fn 流程请使用“语音输入”页。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("识别时会一并发送词典中的已确认词条作为名称参考；词典修改从下一次识别生效。")
                    .font(.callout).foregroundStyle(.secondary)
                Text(recording.status).font(.headline)
                    .accessibilityIdentifier("microphone-status")
                ForEach(recording.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                if let message = recording.playbackMessage { Text(message).foregroundStyle(.orange) }
                if let message = recording.cleanupMessage {
                    Text(message).foregroundStyle(.orange)
                    Button("重试清理") { recording.cleanAbandonedRecordings() }
                }
                if recording.permissionDenied {
                    Button("打开麦克风权限设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if recording.state == .recording {
                    ProgressView(value: recording.elapsed, total: 5)
                    Text(String(format: "已录制 %.1f / 5 秒", recording.elapsed))
                    ProgressView("实时输入音量", value: Double(recording.level), total: 1)
                }
                HStack {
                    Button("录制 5 秒") {
                        simulation.handleEscape()
                        recognition.reset()
                        recording.beginRecording()
                    }
                    .disabled(recording.isBusy || recognition.isBusy)
                    Button("取消录音") { recording.cancelIfActive() }
                        .disabled(recording.state != .recording && recording.state != .requestingPermission)
                    Button(recording.state == .playing ? "停止播放" : "播放录音") {
                        if recording.state == .playing { recording.stopPlayback() }
                        else { recording.play() }
                    }
                    .disabled(recognition.isBusy || (recording.state != .ready && recording.state != .playing))
                }
                if recording.state == .ready || recording.state == .playing {
                    Text(String(format: "本次录音：%.2f 秒 · %.1f KB · WAV", recording.clipDuration, Double(recording.clipBytes) / 1024))
                }
                Button("删除测试录音") {
                    recognition.reset()
                    recording.deleteClip()
                }
                    .disabled(recording.isBusy || recognition.isBusy || !recording.canDeleteClip)
                Divider()
                HStack {
                    Button("识别这段录音") {
                        simulation.handleEscape()
                        recognition.begin(file: recording.clipURL)
                    }.disabled(recording.state != .ready || recognition.isBusy)
                    Button("取消识别") { recognition.cancelIfActive() }.disabled(!recognition.isBusy)
                    if recognition.isBusy { ProgressView().controlSize(.small) }
                }
                Text(recognition.status).accessibilityIdentifier("recognition-status")
                if !recognition.text.isEmpty {
                    Text(recognition.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("recognition-result")
                }
                Text("每次点击识别会使用 API 额度；失败不自动重试。取消会停止本机等待，已经发送的请求仍可能计费。此处只显示原始转写，暂不整理表达或输入其他应用。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("只保留本次临时录音。重新录制、删除或正常退出会清理；录音时取消会丢弃本次录音，停止回放会保留录音。切换测试页、关闭窗口或系统睡眠会停止正在进行的测试。异常退出留下的本版临时文件会在下次启动清理。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("本页的录制、识别和取消按钮不需要输入监控权限。页面在前台时 Esc 可取消；若已开启全局 Fn / Esc 监听，切到其他应用后也可用 Esc 取消。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
        }
        .onExitCommand { recording.cancelIfActive(); recognition.cancelIfActive() }
        .onDisappear { recording.cancelIfActive(); recognition.cancelIfActive() }
    }
}
