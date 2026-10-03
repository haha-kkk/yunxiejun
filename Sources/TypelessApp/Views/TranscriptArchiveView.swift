import SwiftUI

struct TranscriptArchiveView: View {
    @ObservedObject var archive: TranscriptArchiveController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("归档").font(.title).bold()
                Spacer()
                Button("刷新") { archive.reload() }.disabled(archive.isLoading)
            }
            Text("已完成的整理结果保存在这台 Mac 上。关闭浮窗、开始下一次录音或重启应用后，仍可在这里找回。取消的会话不保存；这里不保存原始录音或原始转写。")
                .font(.callout).foregroundStyle(.secondary)
            if archive.isSaving { Text("正在保存结果…").font(.callout) }
            if let error = archive.saveError {
                Text(error).foregroundStyle(.red)
                Button("重试保存") { archive.retrySaving() }.disabled(archive.isSaving)
            }
            if let error = archive.loadError { Text(error).foregroundStyle(.red) }
            if !archive.copyStatus.isEmpty { Text(archive.copyStatus).font(.callout) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if archive.entries.isEmpty && !archive.isLoading && archive.loadError == nil {
                        Text("暂无归档，完成一次语音输入后会显示在这里。")
                    }
                    ForEach(archive.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(entry.createdAt.formatted(date: .numeric, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("复制这条") { archive.copy(entry) }
                            }
                            Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if archive.isLoading { ProgressView("读取中…") }
                    if archive.hasMore { Button("加载更早记录") { archive.loadMore() }.disabled(archive.isLoading) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(minWidth: 480, minHeight: 380)
    }
}
