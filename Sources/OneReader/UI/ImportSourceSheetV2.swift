#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

struct ImportSourceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var urlText = ""
    @State private var destination: ImportDestination = .inbox
    @FocusState private var isURLFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("添加阅读材料")
                            .font(.title2.weight(.semibold))
                        Text("文件、网页或一本仓库书，自动选择合适的阅读方式。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { dismiss() }
                        .frame(minHeight: ReaderChromeMetrics.actionHeight)
                }

                Group {
#if os(macOS)
                    if dynamicTypeSize.isAccessibilitySize {
                        destinationPicker.pickerStyle(.menu)
                    } else {
                        destinationPicker.pickerStyle(.segmented)
                    }
#else
                    destinationPicker.pickerStyle(.menu)
#endif
                }

                VStack(alignment: .leading, spacing: 12) {
                    ImportOptionCard(
                        title: "本地材料",
                        subtitle: "文件、目录或本地 Git 仓库",
                        systemImage: "folder.badge.plus"
                    ) {
                        model.presentLocalSourceImporter(destination: destination)
                        dismiss()
                    }
                    .accessibilityIdentifier("import-local-materials")

#if os(macOS)
                    Label("也可从 Finder 拖入文件或目录，一次添加多个项目。", systemImage: "arrow.down.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("网页或公开 GitHub URL", systemImage: "link")
                        .font(.headline)
#if os(macOS)
                    HStack {
                        urlField
                        pasteButton
                        importButton
                    }
#else
                    VStack(alignment: .leading, spacing: 10) {
                        urlField
                        ReaderAdaptiveActions {
                            pasteButton
                            importButton
                        }
                    }
#endif
                    Text("收集链接无需联网；打开 OneReader 后取回离线副本。已接收不等于下载完成。仅支持 HTTPS 和公开仓库。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(15)
                .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
                .overlay { RoundedRectangle(cornerRadius: ReaderTheme.panelRadius).stroke(.separator.opacity(0.4), lineWidth: 0.5) }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(ReaderTheme.teal)
                    Text(storageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(platformPadding)
#if os(macOS)
            .frame(minWidth: 500, idealWidth: 650)
#endif
        }
        .background(ReaderTheme.grouped)
#if os(macOS)
        .frame(minHeight: 440, idealHeight: 520)
        .onAppear { isURLFocused = true }
#endif
    }

    private var destinationPicker: some View {
        Picker("添加后", selection: $destination) {
            Text("待整理").tag(ImportDestination.inbox)
            Text("直接阅读").tag(ImportDestination.newSpace)
            if model.selectedSpace != nil {
                Text("当前空间").tag(ImportDestination.currentSpace)
            }
        }
    }

    private var urlField: some View {
        TextField("https://…", text: $urlText)
            .textFieldStyle(.roundedBorder)
            .focused($isURLFocused)
            .onSubmit(importURL)
            .accessibilityLabel("来源 URL")
    }

    private var pasteButton: some View {
        Button {
            if let value = clipboardString {
                urlText = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } label: {
            ReaderActionLabel(title: "粘贴", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("从剪贴板粘贴来源 URL")
    }

    private var importButton: some View {
        Button { importURL() } label: {
            ReaderActionLabel(title: destination == .inbox ? "接收链接" : "导入", systemImage: "arrow.down")
        }
            .buttonStyle(.borderedProminent)
            .disabled(parsedURL == nil)
    }

    private var clipboardString: String? {
#if os(macOS)
        NSPasteboard.general.string(forType: .string)
#else
        UIPasteboard.general.string
#endif
    }

    private var storageDescription: String {
#if os(macOS)
        "原始内容存放在 ~/Library/Application Support/OneReader。模型未配置、断网或智能整理失败时，阅读、目录、搜索、标注和进度仍可使用。"
#else
        "材料会复制到 OneReader 的设备内 App 沙盒。模型未配置、断网或智能整理失败时，阅读、目录、搜索、标注和进度仍可使用。"
#endif
    }

    private var platformPadding: CGFloat {
#if os(macOS)
        24
#else
        20
#endif
    }

    private var parsedURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    private func importURL() {
        guard let url = parsedURL else { return }
        model.importRemoteURL(url, destination: destination)
        dismiss()
    }
}

private struct ImportOptionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(ReaderTheme.teal)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
            .overlay { RoundedRectangle(cornerRadius: ReaderTheme.panelRadius).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }
}
