import AppKit

/// 睡眠、显示器休眠及用户会话切换时丢弃旧会话和未松开的 Fn。
@MainActor
final class SessionInterruptionMonitor {
    private let center: NotificationCenter
    private var observations: [NSObjectProtocol] = []
    private weak var session: SessionValidationController?
    private weak var keyboard: FnKeyMonitor?
    private let onInterruption: @MainActor () -> Void

    init(
        session: SessionValidationController,
        keyboard: FnKeyMonitor,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onInterruption: @escaping @MainActor () -> Void = {}
    ) {
        self.center = center
        self.session = session
        self.keyboard = keyboard
        self.onInterruption = onInterruption
        let notifications: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            // 唤醒时再清理一次，防止睡眠期间丢失松键事件或旧会话残留。
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in notifications {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                    // 在主线程直接取消，不另起异步任务延后到下一轮会话。
                    MainActor.assumeIsolated {
                        self?.keyboard?.resetPendingFn()
                        self?.session?.handleSystemInterruption()
                        self?.onInterruption()
                    }
            })
        }
    }

    deinit {
        for observation in observations { center.removeObserver(observation) }
    }
}
