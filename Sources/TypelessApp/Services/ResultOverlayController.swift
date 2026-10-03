import AppKit
import Combine
import SwiftUI

private final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 出现和点击复制都不激活应用，原来的输入框仍保留键盘焦点。
@MainActor
final class ResultOverlayController {
    private let panel: NSPanel
    private var observation: AnyCancellable?

    init(model: ResultOverlayModel) {
        let size = NSSize(width: 480, height: 420)
        panel = ResultPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "云写君 · 复制最后的转录"
        panel.level = .floating; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSHostingView(rootView: ResultOverlayView(model: model))
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.setContentSize(size)
        observation = model.$content.sink { [weak self] result in
            guard let self else { return }
            guard result != nil else { self.panel.orderOut(nil); return }
            if !self.panel.isVisible {
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    let fitted = NSSize(width: min(size.width, frame.width - 32), height: min(size.height, frame.height - 32))
                    self.panel.setContentSize(fitted)
                    self.panel.setFrameOrigin(NSPoint(x: frame.midX - fitted.width / 2, y: frame.minY + 16))
                }
            }
            self.panel.orderFrontRegardless()
        }
    }
}
