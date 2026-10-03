import SwiftUI

/// 浮窗只是会话状态的展示，不维护另一套会话状态。
enum SessionOverlayPhase: Equatable {
    case recording
    case processing

    init?(state: DictationSession.State) {
        switch state {
        case .recording: self = .recording
        case .processing: self = .processing
        default: return nil
        }
    }
}

struct SessionOverlayView: View {
    let phase: SessionOverlayPhase
    var simulated = true

    var body: some View {
        HStack(spacing: 14) {
            if phase == .recording {
                Image(systemName: "waveform")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                    .accessibilityLabel("正在处理")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(phase == .recording ? (simulated ? "模拟录音中" : "录音中") : "Thinking")
                    .font(.system(size: 17, weight: .semibold))
                Text(phase == .recording ? "Fn 结束 · Esc 取消" : (simulated ? "模拟处理中 · Esc 取消" : "识别与整理 · Esc 取消"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 280, height: 76)
        .background(.black.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}
