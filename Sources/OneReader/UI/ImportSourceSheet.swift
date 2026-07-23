import SwiftUI

struct ImportSourceSheet: View {
    enum ImportKind: String, CaseIterable, Identifiable {
        case github
        case pdf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .github: "GitHub Repo"
            case .pdf: "本地 PDF"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ImportKind = .github
    @State private var repositoryURL = DemoCatalog.repositoryURL.absoluteString

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加内容空间")
                        .font(.title2.weight(.semibold))
                    Text("原始材料保持原样，OneReader 只建立定位和阅读结构。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
            }

            Picker("来源类型", selection: $kind) {
                ForEach(ImportKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch kind {
                case .github:
                    githubForm
                case .pdf:
                    pdfForm
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Label(
                    kind == .github
                        ? "仅访问公开仓库，不需要 Token"
                        : "PDF 字节不会离开这台 Mac",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                if kind == .github {
                    Button("导入并生成路线") {
                        model.importRepository(urlString: repositoryURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty || model.isImporting)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 370)
    }

    private var githubForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("公开的 Repo 书籍", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            TextField("https://github.com/owner/repository", text: $repositoryURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("GitHub 仓库地址")

            Text("OneReader 会解析默认分支、精确 commit SHA、README 目录和 Markdown 文件；章节正文只在选中时读取。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isImporting {
                ProgressView("正在构建 Source Snapshot…")
                    .controlSize(.small)
            }
        }
        .readerCard()
    }

    private var pdfForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("本地 PDF 文档", systemImage: "doc.richtext")
                .font(.headline)

            Text("使用系统文件选择器打开 PDF。OneReader 会计算内容摘要，并从原生目录或页组生成可恢复的阅读单元。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.presentLocalPDFImporter()
            } label: {
                Label("选择 PDF…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isImporting)
        }
        .readerCard()
    }
}
