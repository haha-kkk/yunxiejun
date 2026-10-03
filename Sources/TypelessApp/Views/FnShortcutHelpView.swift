import SwiftUI

struct FnShortcutHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("单独按下并松开 Fn 才触发；Fn 组合键不触发。")
            Text("若按 Fn 时还会切换输入法或弹出系统面板，请到“系统设置 → 键盘 → 按下 🌐 键时”，选择“不执行任何操作”。本工具不会自动修改系统设置。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
