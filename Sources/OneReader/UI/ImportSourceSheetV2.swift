import SwiftUI

struct ImportSourceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var destination: ImportDestination = .newSpace
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("添加阅读材料")
                        .font(.title2.weight(.semibold))
                    Text("无需先判断类型。OneReader 会创建不可变快照，并让基础适配器立即提供可读界面。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
            }

            if model.selectedSpace != nil {
                Picker("添加方式", selection: $destination) {
                    Text("创建新的 Reading Space").tag(ImportDestination.newSpace)
                    Text("加入“\(model.selectedSpace?.title ?? "当前空间")”")
                        .tag(ImportDestination.currentSpace)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 14) {
                ImportOptionCard(
                    title: "本地材料",
                    subtitle: "文件、目录或本地 Git 仓库",
                    systemImage: "folder.badge.plus"
                ) {
                    model.presentLocalSourceImporter(destination: destination)
                    dismiss()
                }

                ImportOptionCard(
                    title: "拖放到窗口",
                    subtitle: "Finder 中可一次拖入多个项目",
                    systemImage: "arrow.down.doc"
                ) {}
                .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("网页或公开 GitHub URL", systemImage: "link")
                    .font(.headline)
                HStack {
                    TextField("https://…", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isURLFocused)
                        .onSubmit(importURL)
                        .accessibilityLabel("来源 URL")
                    Button("从剪贴板粘贴") {
                        if let value = NSPasteboard.general.string(forType: .string) {
                            urlText = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    Button("导入") { importURL() }
                        .buttonStyle(.borderedProminent)
                        .disabled(parsedURL == nil)
                }
                Text("网页会保存受控离线快照；GitHub 仓库固定到 exact commit SHA。仅支持 HTTPS 和公开仓库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(ReaderTheme.teal)
                Text("原始内容存放在 ~/Library/Application Support/OneReader。模型未配置、断网或 Agent 失败时，阅读、目录、搜索、标注和进度仍可使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 650, height: 455)
        .onAppear { isURLFocused = true }
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
                    .font(.system(size: 25))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
        }
        .buttonStyle(.plain)
    }
}
