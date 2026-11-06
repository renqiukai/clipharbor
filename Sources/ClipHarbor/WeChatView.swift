import SwiftUI
import AppKit

@MainActor
struct WeChatView: View {
    @State private var clipboardText: String?
    @State private var clipboardMetadata: Data?
    @State private var diagnostic = ""
    @State private var diagnosticExpanded = false
    @State private var clipboardSummary = "正在读取剪贴板…"
    @State private var clipboardWarning: String?
    @State private var source: URL? = WeChatView.defaultSource
    @ObservedObject var exportSession: WeChatExportSession

    private static var defaultSource: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(HarborStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(HarborStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("微信聊天导出").font(.system(size: 20, weight: .semibold))
                    Text("复制聊天记录，整理成文字与图片。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("本机处理", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        clipboardSection.padding(16)
                        Divider().padding(.horizontal, 16)
                        sourceSection.padding(16)
                    }
                    .background(HarborStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
                    if let result = exportSession.result { resultSection(result) }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if exportSession.working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(exportSession.status).font(.system(size: 12))
                        Spacer()
                        Text("已扫描 \(exportSession.scanned) 个项目")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if !exportSession.status.isEmpty {
                    Text(exportSession.status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("转换时会读取最新剪贴板")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if exportSession.working {
                        Button("取消") { exportSession.cancel() }
                            .buttonStyle(.bordered).controlSize(.large)
                            .accessibilityLabel("取消聊天导出")
                    }
                    Button { export() } label: {
                        Label("自动转换并保存", systemImage: "arrow.down.doc")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(exportSession.working || exportSession.isTerminating)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(HarborStyle.surface)
        }
        .frame(width: 600, height: 480)
        .background(HarborStyle.canvas)
        .tint(HarborStyle.accent)
        .onAppear { readClipboard() }
        .alert("微信聊天导出", isPresented: Binding(get: { exportSession.error != nil }, set: { if !$0 { exportSession.error = nil } })) {
            Button("好") { exportSession.error = nil }
        } message: { Text(exportSession.error ?? "") }
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("剪贴板", systemImage: "clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(clipboardText == nil ? "待复制" : "已就绪")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(clipboardText == nil ? Color.secondary : HarborStyle.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((clipboardText == nil ? Color.secondary : HarborStyle.accent).opacity(0.08), in: Capsule())
                Button { readClipboard() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).padding(.leading, 4)
                .help("读取并诊断剪贴板").accessibilityLabel("读取并诊断剪贴板")
                .disabled(exportSession.working)
            }
            Text(clipboardSummary).font(.system(size: 12)).foregroundStyle(.secondary)
            if let clipboardWarning {
                Label(clipboardWarning, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("诊断详情", isExpanded: $diagnosticExpanded) {
                Text(diagnostic).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("图片搜索目录", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if source != nil {
                    Button("移除") { source = nil }.foregroundStyle(.secondary)
                }
                Button("更换目录…") { chooseSource() }
            }
            .buttonStyle(.borderless).font(.system(size: 12))
            .disabled(exportSession.working)
            Text(source?.path ?? "未选择目录，图片将标记为未匹配。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Text("优先按微信复制数据关联；无法确认的图片会保留原引用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ result: WeChatExport.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("转换完成", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(HarborStyle.accent)
                Spacer()
                Button("在访达中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([result.directory]) }
                    .buttonStyle(.bordered).font(.system(size: 12))
            }
            HStack(spacing: 16) {
                Text("\(result.messages) 条消息")
                Text("\(result.matched) 项图片已匹配")
                Text("\(result.unmatched) 项未匹配")
                    .foregroundStyle(result.unmatched > 0 ? Color.orange : Color.secondary)
            }.font(.system(size: 12)).monospacedDigit()
            if result.unmatched > 0 {
                Text("未匹配原因已写入 conversation.md 底部的「图片关联报告」。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(result.directory.path).font(.system(size: 11)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Text("将 conversation.md 和 images 中的图片分别提供给 ChatGPT，并检查关联报告。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func readClipboard() {
        let board = NSPasteboard.general
        let sensitive = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"].map { NSPasteboard.PasteboardType($0) }
        exportSession.result = nil
        guard board.availableType(from: sensitive) == nil else {
            clipboardText = nil
            clipboardMetadata = nil
            diagnostic = "剪贴板标记为敏感或临时内容，未读取。"
            clipboardSummary = diagnostic
            clipboardWarning = nil
            return
        }
        let types = (board.types ?? []).map(\.rawValue).sorted()
        let itemTypes = (board.pasteboardItems ?? []).enumerated().map { index, item in
            "项目 \(index + 1)：\(item.types.map(\.rawValue).sorted().joined(separator: ", "))"
        }.joined(separator: "\n")
        let text = board.string(forType: .string)
        clipboardMetadata = board.data(forType: NSPasteboard.PasteboardType("com.trolltech.anymime.x-xwechat-multiselect-copy"))
        clipboardText = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let parsed = clipboardText.map { WeChatExport.parse($0, clipboardMetadata: clipboardMetadata) }
        let imageCount = clipboardText.map { WeChatExport.references(in: $0).count } ?? 0
        clipboardSummary = clipboardText == nil ? "尚未读取到可转换的文字，请先在微信中复制聊天记录。" : "已读取文字，识别 \(parsed?.messages.count ?? 0) 条消息、\(imageCount) 项图片引用。"
        clipboardWarning = parsed?.warning
        diagnostic = "格式：\(types.isEmpty ? "无" : types.joined(separator: ", "))\n\(itemTypes)\n文本：\(clipboardText == nil ? "无" : "有")；识别消息：\(parsed?.messages.count ?? 0)；图片引用：\(imageCount)"
        if let warning = parsed?.warning { diagnostic += "\n" + warning }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择搜索目录"
        if panel.runModal() == .OK { source = panel.url }
    }

    private func export() {
        readClipboard()
        guard let text = clipboardText else {
            exportSession.error = "当前剪贴板没有可转换的文字，请先在微信中复制聊天记录。"
            return
        }
        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHarbor/微信聊天导出", isDirectory: true)
        let selectedSource = source
        let metadata = clipboardMetadata
        exportSession.start { progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return try WeChatExport.export(text: text, source: selectedSource, destination: destination, clipboardMetadata: metadata,
                                           progress: progress)
        }
    }
}
