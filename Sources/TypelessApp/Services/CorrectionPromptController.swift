import AppKit
import Combine
import SwiftUI

private final class CorrectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 提示能接收鼠标点击，但出现时不激活应用、不抢走原文本框键盘焦点。
@MainActor
final class CorrectionPromptController {
    private let panel: NSPanel
    private var observation: AnyCancellable?

    init(learning: CorrectionLearningController) {
        let size = NSSize(width: 380, height: 320)
        panel = CorrectionPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "云写君 · 术语确认"
        panel.level = .floating; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 没有候选时 SwiftUI 内容为空，不能让它把原生窗口收缩到零宽。
        // 固定外层尺寸，并关闭自动尺寸约束；首次定位和后续提示均使用同一窗口尺寸。
        let content = NSHostingView(rootView: CorrectionPromptView(learning: learning)
            .frame(width: size.width, height: size.height, alignment: .top))
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.setContentSize(size)
        observation = learning.$pending.sink { [weak self] candidates in
            guard let self else { return }
            guard !candidates.isEmpty else { self.panel.orderOut(nil); return }
            if !self.panel.isVisible {
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    self.panel.setFrameOrigin(NSPoint(x: frame.maxX - self.panel.frame.width - 24, y: frame.minY + 28))
                }
            }
            self.panel.orderFrontRegardless()
        }
    }
}
