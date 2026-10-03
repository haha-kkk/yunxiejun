import SwiftUI

struct CorrectionLearningView: View {
    @ObservedObject var learning: CorrectionLearningController
    @ObservedObject private var probe: ExternalTextProbeController

    init(learning: CorrectionLearningController) { self.learning = learning; self.probe = learning.probe }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("术语学习验证").font(.title).bold()
                Text("先在文本编辑中准备“请用 Cloud 整理需求。”，再开始观察。切回正文后等两秒，把 Cloud 改成 Claude，再等两秒。每轮只登记一次稳定改词；下一轮先准备 Cloude 或 Cloud AI，再开始观察。")
                Text("只观察所选应用 60 秒。计数仅保存改前／改后的词语，不保存整段正文。累计三次会显示“是的／取消”；确认后才入词典。本页暂未连接 Fn 的语音输出流程。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("点击“取消”后，再累计三次新的纠正才重新询问；计数和选择在重启后保留。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(probe.hasPermission ? "辅助功能：已授权" : "辅助功能：未授权")
                    Button("检查权限") { probe.checkPermission() }
                    Button("打开辅助功能设置") { probe.openPermissionSettings() }.disabled(probe.isRunning)
                }
                HStack {
                    Picker("目标应用", selection: $probe.selectedPID) {
                        if probe.targets.isEmpty { Text("请先打开文本编辑").tag(Int32(0)) }
                        ForEach(probe.targets) { Text($0.name).tag($0.id) }
                    }.disabled(probe.isRunning || learning.isSaving)
                    Button("刷新应用") { probe.refreshTargets() }.disabled(probe.isRunning)
                }
                HStack {
                    Button("开始观察一次改词") { learning.startObserving() }
                        .disabled(probe.isRunning || learning.isSaving || learning.canRetry || probe.selectedPID == 0)
                    Button("停止观察") { learning.stopObserving() }.disabled(!probe.isRunning)
                    if probe.isRunning { Text("剩余 \(probe.remainingSeconds) 秒") }
                }
                Text(probe.status)
                Text("最近前台：\(probe.foregroundName)；读取成功 \(probe.successfulReads) 次")
                    .font(.callout).foregroundStyle(.secondary)
                Text(learning.notice).accessibilityIdentifier("learning-notice")
                if let last = learning.lastCount {
                    Text("\(last.text)：累计 \(last.count) 次").font(.headline)
                }
                if learning.isSaving { ProgressView("正在保存…").controlSize(.small) }
                if let error = learning.error { Text(error).foregroundStyle(.red) }
                if learning.canRetry {
                    HStack {
                        Button("重试保存这次纠正") { learning.retryRecording() }
                        Button("放弃这次未保存的纠正") { learning.discardFailedRecording() }
                    }
                }
                Divider()
                HStack {
                    Text("待确认建议：\(learning.pending.count) 条")
                    Button("刷新待确认") { learning.reloadPending() }.disabled(learning.isLoading || learning.isSaving)
                }
                if !learning.pending.isEmpty { CorrectionPromptView(learning: learning) }
                Text("不支持的输入框、跨框编辑和整段改写不会被强行记为术语。关闭页面或窗口会停止观察；已经达到三次的建议保留，重开后仍可确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { probe.refreshTargets(); learning.reloadPending() }
        .onDisappear { learning.stopObserving() }
    }
}

struct CorrectionPromptView: View {
    @ObservedObject var learning: CorrectionLearningController

    var body: some View {
        if let candidate = learning.pending.first {
            VStack(alignment: .leading, spacing: 12) {
                Text("把这个词加入词典？").font(.headline)
                Text("“\(candidate.text)”").font(.title3).bold().fixedSize(horizontal: false, vertical: true)
                Text("已累计纠正 \(candidate.count) 次。").foregroundStyle(.secondary)
                if let error = learning.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
                HStack {
                    if learning.isSaving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("取消") { learning.decide(accept: false) }.disabled(learning.isSaving)
                    Button("是的") { learning.decide(accept: true) }.disabled(learning.isSaving)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("correction-confirmation")
        }
    }
}
