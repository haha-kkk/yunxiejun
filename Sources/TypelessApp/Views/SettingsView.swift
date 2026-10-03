import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var api: APISettingsController
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            VocabularyListView().tabItem { Text("词典") }.tag(0)
            GeneralSettingsView().tabItem { Text("API 与快捷键") }.tag(1)
        }
        .padding(8)
        .frame(minWidth: 560, minHeight: 500)
        .onChange(of: selectedTab) { _, _ in api.clearDraft() }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var api: APISettingsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置").font(.title).fontWeight(.semibold)

                GroupBox("阿里百炼 API · 北京地域") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("识别：Qwen3-ASR-Flash\n整理：千问 Flash")
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("密钥状态：\(api.status.label)").fontWeight(.medium)
                            if api.isBusy { ProgressView().controlSize(.small) }
                        }
                        SecureField("粘贴北京地域 API Key", text: $api.draftKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(api.isBusy)
                            .accessibilityIdentifier("bailian-api-key")
                        HStack {
                            Button(api.status == .configured ? "替换密钥" : "保存密钥") {
                                api.beginSave()
                            }.disabled(api.isBusy || api.draftKey.isEmpty)
                            Button("删除已保存的密钥") { Task { await api.delete() } }
                                .disabled(api.isBusy || api.status != .configured)
                            Button("刷新状态") { Task { await api.refresh() } }.disabled(api.isBusy)
                        }
                        Text("密钥保存在 Mac 钥匙串，不显示已有密钥。需要更换时重新粘贴；关闭设置会清空尚未保存的输入。")
                            .font(.callout).foregroundStyle(.secondary)
                        if let message = api.message {
                            Text(message).foregroundStyle(api.isError ? Color.red : Color.secondary)
                                .font(.callout)
                        }
                    }.padding(8)
                }

                Divider()
                Text("Fn 快捷键使用说明").font(.headline)
                FnShortcutHelpView()
            }.padding(24)
        }
        .frame(minWidth: 540, minHeight: 470)
    }
}
