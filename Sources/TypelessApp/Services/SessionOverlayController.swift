import AppKit
import Combine
import SwiftUI

/// 不激活应用、不成为键盘窗口，让原来的输入框继续接收键盘输入。
private final class SessionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SessionOverlayController {
    private let panel: NSPanel
    private let simulated: Bool
    private var observation: AnyCancellable?

    convenience init(session: SessionValidationController) {
        self.init(phases: session.$state.map { SessionOverlayPhase(state: $0) }.eraseToAnyPublisher(), simulated: true)
    }

    init(phases: AnyPublisher<SessionOverlayPhase?, Never>, simulated: Bool = false) {
        self.simulated = simulated
        panel = SessionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "云写君 · 会话状态"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // @Published 在赋值前通知订阅者，必须使用传入的新状态。
        observation = phases.sink { [weak self] phase in
            self?.display(phase)
        }
    }

    private func display(_ phase: SessionOverlayPhase?) {
        guard let phase else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            // 每轮首次显示时选鼠标所在屏幕，录音转处理时位置保持不变。
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.minY + 28
                ))
            }
        }
        panel.contentView = NSHostingView(rootView: SessionOverlayView(phase: phase, simulated: simulated))
        // 不能调用 activate 或 makeKeyAndOrderFront，否则会抢走外部输入焦点。
        panel.orderFrontRegardless()
    }
}
