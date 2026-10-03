import SwiftUI

struct EscValidationView: View {
    @EnvironmentObject private var monitor: FnKeyMonitor
    @EnvironmentObject private var controller: SessionValidationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Esc 取消验证").font(.title).fontWeight(.semibold)
            Text("按钮只模拟会话状态，不会录音、联网、输入文字或修改剪贴板。")
                .foregroundStyle(.secondary)
            HStack {
                Text(monitor.isListening ? "按键监听已开启" : "请先开启按键监听")
                Spacer()
                Button(monitor.isListening ? "停止按键监听" : "开启按键监听") {
                    if monitor.isListening { monitor.stop() } else { monitor.start() }
                }
            }
            Text(monitor.status).font(.callout).foregroundStyle(.secondary)
            if !monitor.hasListenPermission {
                Text("需要在系统设置 → 隐私与安全性 → 输入监控中允许 云写君，然后重新开启监听。")
                    .font(.callout)
            }
            Divider()
            Text("会话状态：\(controller.stateTitle)").font(.headline)
            if controller.isProcessing {
                ProgressView("Thinking（模拟处理中）")
            }
            HStack {
                Button("开始模拟录音") { controller.startRecording() }
                    .disabled(!monitor.isListening || !controller.canStart)
                Button("结束模拟录音") { controller.finishRecording() }
                    .disabled(!controller.isRecording)
                Button("模拟结果返回") { controller.simulateResult() }
                    .disabled(!controller.canSimulateResult)
            }
            Text("录音中或处理中按 Esc 应变为“已取消”；Thinking 随之消失。取消后再点“模拟结果返回”，应显示结果已拦截。")
                .font(.callout)
            Text(controller.resultNotice).foregroundStyle(.secondary)
            if let output = controller.outputText {
                Text("模拟输出：\(output)")
            } else {
                Text("模拟输出：无")
            }
            Spacer(minLength: 0)
            Text("切换到其他应用后也可按 Esc 测试。这里只观察按键，Esc 仍会传给当前应用；空闲时本工具不取消任何会话。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
