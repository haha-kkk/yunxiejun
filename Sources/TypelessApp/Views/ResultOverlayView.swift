import SwiftUI

struct ResultOverlayView: View {
    @ObservedObject var model: ResultOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.blue)
                Text("复制最后的转录").font(.title2).bold()
                Spacer()
                Button { model.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭结果浮窗")
            }
            if let content = model.content {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(content.notice).font(.callout).foregroundStyle(.secondary)
                        Text(content.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("result-overlay-text")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("复制") { model.copy() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("result-overlay-copy")
                    Text(model.copyStatus).font(.callout).accessibilityIdentifier("result-overlay-copy-status")
                    Spacer()
                    Button("打开归档") { model.openArchive() }
                }
            }
            Text("仅点击“复制”才写入剪贴板。浮窗显示 10 分钟，关闭后可从“归档”找回已保存结果。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        .padding(1)
    }
}
