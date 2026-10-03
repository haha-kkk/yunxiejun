import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var correctionLearning: CorrectionLearningController
    @EnvironmentObject private var dictation: DictationController
    var body: some View {
        TabView {
            DictationView().tabItem { Text("语音输入") }
            FnValidationView().tabItem { Text("Fn 按键验证") }
            EscValidationView().disabled(dictation.isBusy).tabItem { Text("Esc 取消验证") }
            MicrophoneRecordingView().disabled(dictation.isBusy).tabItem { Text("麦克风录音") }
            TextCleanupView().disabled(dictation.isBusy).tabItem { Text("文字整理") }
            ExternalTextProbeView().disabled(dictation.isBusy).tabItem { Text("输入框验证") }
            CorrectionLearningView(learning: correctionLearning).disabled(dictation.isBusy).tabItem { Text("术语学习") }
        }
        .padding(8)
        .frame(minWidth: 660, minHeight: 560)
    }
}

private struct FnValidationView: View {
    @EnvironmentObject private var monitor: FnKeyMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fn 按键验证")
                .font(.title)
                .fontWeight(.semibold)

            Text("此页显示按键记录。开启监听后，Fn 已连接真实语音输入：首次开始录音，再按结束并自动识别、整理和输出；Esc 取消。结果请看“语音输入”页。")
                .foregroundStyle(.secondary)

            FnShortcutHelpView()

            HStack {
                Circle()
                    .fill(monitor.isListening ? .green : .gray)
                    .frame(width: 9, height: 9)
                Text(monitor.status)
                Spacer()
                Button(monitor.isListening ? "停止监听" : "开始监听 Fn") {
                    if monitor.isListening {
                        monitor.stop()
                    } else {
                        monitor.start()
                    }
                }
            }

            if !monitor.hasListenPermission && !monitor.isListening {
                Text("如果 macOS 没有弹出权限提示，请到“系统设置 → 隐私与安全性 → 输入监控”，允许当前运行此应用的程序监听键盘输入，然后重新开始监听。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("按键记录")
                .font(.headline)

            if monitor.events.isEmpty {
                Text("开始监听后，按下再松开 Fn，这里会各出现一条记录。")
                    .foregroundStyle(.secondary)
            } else {
                List(monitor.events) { event in
                    HStack {
                        Text(event.action)
                        Spacer()
                        Text(event.time.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 360)
    }
}
