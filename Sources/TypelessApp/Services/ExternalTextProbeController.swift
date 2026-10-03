import AppKit
import ApplicationServices
import Combine

@MainActor
final class ExternalTextProbeController: ObservableObject {
    @Published private(set) var targets: [ExternalTextTarget] = []
    @Published var selectedPID: Int32 = 0
    @Published private(set) var hasPermission = false
    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var status = "选择目标应用后，手动开始验证。"
    @Published private(set) var snapshot: ExternalTextSnapshot?
    @Published private(set) var changes: [ExternalTextChange] = []
    @Published private(set) var targetName = "尚未开始"
    @Published private(set) var foregroundName = "尚未检查"
    @Published private(set) var readAttempts = 0
    @Published private(set) var successfulReads = 0
    @Published private(set) var lastReadStatus = "尚未读取目标输入框。"
    // 默认不接收者，T19 仍然只读；T21 的独立验证器显式订阅稳定改词。
    var onSample: ((ExternalTextSnapshot) -> Void)?
    var onContinuityBreak: (() -> Void)?
    private let reader: any ExternalTextReading
    private let trusted: () -> Bool
    private let foregroundPID: () -> Int32?
    private let isAlive: (Int32) -> Bool
    private let duration: Duration
    private let interval: Duration
    private var comparison = ExternalTextComparison()
    private var runID: UUID?
    private var task: Task<Void, Never>?

    init(
        reader: any ExternalTextReading = ExternalTextReader(),
        trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        foregroundPID: @escaping () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        isAlive: @escaping (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isTerminated == false },
        duration: Duration = .seconds(60), interval: Duration = .milliseconds(500)
    ) {
        self.reader = reader; self.trusted = trusted; self.foregroundPID = foregroundPID
        self.isAlive = isAlive; self.duration = duration; self.interval = interval
    }

    func refreshTargets() {
        guard !isRunning else { return }
        targets = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { ExternalTextTarget(id: $0.processIdentifier, name: $0.localizedName ?? "未命名应用", bundleIdentifier: $0.bundleIdentifier ?? "") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !targets.contains(where: { $0.id == selectedPID }) { selectedPID = targets.first?.id ?? 0 }
        checkPermission()
    }

    func checkPermission() { hasPermission = trusted() }

    func openPermissionSettings() {
        // 仅打开系统页面；是否授予由用户在系统设置中决定。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        checkPermission()
    }

    func startSelected() {
        guard let target = targets.first(where: { $0.id == selectedPID }) else { return }
        start(target)
    }

    func start(_ target: ExternalTextTarget) {
        start(target, context: nil)
    }

    func startAfterOutput(_ context: OutputCorrectionContext) {
        guard context.baseline.targetPID == context.target.id else { return }
        start(context.target, context: context)
    }

    private func start(_ target: ExternalTextTarget, context: OutputCorrectionContext?) {
        guard !isRunning else { return }
        clearResults()
        checkPermission()
        guard hasPermission else { status = ExternalTextReadIssue.permissionRequired.message; return }
        guard isAlive(target.id) else { status = "目标应用已退出，请刷新应用列表。"; return }
        let id = UUID(), clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        runID = id; isRunning = true; targetName = target.name
        status = "请切到 \(target.name)，点击要验证的输入框。"
        let reader = context?.reader ?? self.reader
        task = Task { [weak self, reader, interval] in
            while !Task.isCancelled {
                guard let self, self.runID == id else { return }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { self.stop(reason: "验证已到时，已停止读取。结果仅保留在本页内存中。"); return }
                self.remainingSeconds = max(1, Int(remaining.components.seconds) + (remaining.components.attoseconds > 0 ? 1 : 0))
                guard self.trusted() else {
                    self.hasPermission = false
                    self.stop(reason: ExternalTextReadIssue.permissionRequired.message); return
                }
                guard self.isAlive(target.id) else { self.stop(reason: "目标应用已退出，验证已停止。"); return }
                if self.observeForeground() == target.id {
                    self.status = "正在检查所选应用的聚焦输入框…"
                    self.readAttempts += 1
                    let result = await reader.read(targetPID: target.id)
                    guard !Task.isCancelled, self.runID == id else { return }
                    guard self.trusted() else {
                        self.hasPermission = false
                        self.stop(reason: ExternalTextReadIssue.permissionRequired.message); return
                    }
                    guard self.isAlive(target.id) else { self.stop(reason: "目标应用已退出，验证已停止。"); return }
                    guard clock.now < deadline else { self.stop(reason: "验证已到时，已停止读取。"); return }
                    if self.observeForeground() == target.id {
                        if let context {
                            guard case .readable(let sample) = result,
                                  sample.targetPID == context.target.id,
                                  sample.fieldID == context.baseline.fieldID else {
                                self.stop(reason: "原输出框已失焦或不可读取，已停止本轮术语学习。"); return
                            }
                        }
                        self.receive(result, targetPID: target.id)
                    } else if context != nil {
                        self.stop(reason: "已切换应用，停止本轮术语学习。"); return
                    } else { self.waitForTarget(target.name) }
                } else if context != nil {
                    self.stop(reason: "已切换应用，停止本轮术语学习。"); return
                } else { self.waitForTarget(target.name) }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop(reason: String = "已停止读取。结果仅保留在本页内存中。") {
        guard isRunning else { return }
        runID = nil; task?.cancel(); task = nil
        isRunning = false; remainingSeconds = 0; comparison.reset()
        onContinuityBreak?()
        status = reason
    }

    func clearResults() {
        stop()
        snapshot = nil; changes = []; comparison.reset(); targetName = "尚未开始"
        foregroundName = "尚未检查"; readAttempts = 0; successfulReads = 0
        lastReadStatus = "尚未读取目标输入框。"
        status = "结果已清空，未保存到磁盘。"
    }

    private func observeForeground() -> Int32? {
        let pid = foregroundPID()
        foregroundName = pid.map {
            NSRunningApplication(processIdentifier: $0)?.localizedName ?? "未知应用（\($0)）"
        } ?? "系统未提供前台应用"
        return pid
    }

    private func waitForTarget(_ name: String) {
        comparison.reset()
        onContinuityBreak?()
        status = "当前未聚焦 \(name)，已暂停读取；请切到目标应用的输入框。"
    }

    private func receive(_ result: ExternalTextReadResult, targetPID: Int32) {
        switch result {
        case .readable(let sample):
            guard sample.targetPID == targetPID else { comparison.reset(); return }
            successfulReads += 1
            snapshot = sample
            if let change = comparison.receive(sample) {
                changes.insert(change, at: 0)
                changes = Array(changes.prefix(5))
            }
            status = changes.isEmpty ? "输入框可读取；尚未观察到文字修改。" : "已观察到文字修改，请检查下方修改前后内容。"
            lastReadStatus = status
            onSample?(sample)
        case .unavailable(let issue):
            comparison.reset(); status = issue.message; lastReadStatus = issue.message
            onContinuityBreak?()
            if issue == .permissionRequired { hasPermission = false; stop(reason: issue.message) }
        }
    }
}
