import SwiftUI

struct ExternalTextProbeView: View {
    @EnvironmentObject private var probe: ExternalTextProbeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("外部输入框验证").font(.title).bold()
                Text("选择一个已打开的应用，开始后切过去点击输入框。先输入“请用 Cloud 整理需求”，等一秒，再把 Cloud 改为 Claude，等一秒后回来查看。不要发送测试消息。")
                Text("仅在 60 秒验证期间读取所选应用的聚焦文本框，最多显示最近 5 次采样变化；跳过密码框。文字只在本页内存中，不上传、不归档，也不会写入其他应用。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(probe.hasPermission ? "辅助功能：已授权" : "辅助功能：未授权")
                        .accessibilityIdentifier("external-permission")
                    Button("检查权限") { probe.checkPermission() }
                    Button("打开辅助功能设置") { probe.openPermissionSettings() }.disabled(probe.isRunning)
                }
                HStack {
                    Picker("目标应用", selection: $probe.selectedPID) {
                        if probe.targets.isEmpty { Text("请先打开目标应用").tag(Int32(0)) }
                        ForEach(probe.targets) { target in
                            Text("\(target.name)（\(target.id)）").tag(target.id)
                        }
                    }.disabled(probe.isRunning).accessibilityIdentifier("external-target")
                    Button("刷新应用") { probe.refreshTargets() }.disabled(probe.isRunning)
                }
                HStack {
                    Button("开始验证（60 秒）") { probe.startSelected() }
                        .disabled(probe.isRunning || probe.selectedPID == 0)
                    Button("停止") { probe.stop() }.disabled(!probe.isRunning)
                    Button("清空结果") { probe.clearResults() }
                    if probe.isRunning { Text("剩余 \(probe.remainingSeconds) 秒").foregroundStyle(.secondary) }
                }
                Text("本次目标：\(probe.targetName)")
                Text(probe.status).accessibilityIdentifier("external-status")
                GroupBox("本次检查结果（停止后仍保留）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最近检测到的前台应用：\(probe.foregroundName)")
                        Text("尝试读取 \(probe.readAttempts) 次，成功 \(probe.successfulReads) 次")
                        Text("最后读取结果：\(probe.lastReadStatus)")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.accessibilityIdentifier("external-diagnostics")
                if let snapshot = probe.snapshot {
                    GroupBox("最近一次读取（\(snapshot.role)）") {
                        Text(snapshot.text.isEmpty ? "（空输入框）" : snapshot.text)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.accessibilityIdentifier("external-current")
                }
                ForEach(probe.changes) { change in
                    GroupBox("观察到的修改（最新在上）") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("修改前：\(change.before.isEmpty ? "（空）" : change.before)")
                            Text("修改后：\(change.after.isEmpty ? "（空）" : change.after)")
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.accessibilityIdentifier("external-change")
                }
                Text("这里验证的是采样时能否读到变化，并非可靠的逐字修改记录。输入框切换、不可读或应用失焦会重新建立比较基线；不支持的应用仍可使用手动词典。切页、关窗或系统休眠会停止验证。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { probe.refreshTargets() }
        .onDisappear { probe.stop() }
    }
}
