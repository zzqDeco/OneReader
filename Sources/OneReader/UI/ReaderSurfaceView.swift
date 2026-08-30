import PDFKit
import SwiftUI

struct ReaderSurfaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let unit = model.selectedUnit {
                ReaderUnitHeader(unit: unit)
                Divider()
                readerBody(for: unit)
                Divider()
                ReaderNavigationBar(unit: unit)
            } else {
                ContentUnavailableView(
                    "资料库还是空的",
                    systemImage: "books.vertical",
                    description: Text("点击工具栏的“导入材料”，或使用 ⌘⇧O / ⌘⌥O。")
                )
            }
        }
        .background(ReaderTheme.paper)
        .navigationTitle(model.selectedUnit?.title ?? model.graph.title)
    }

    @ViewBuilder
    private func readerBody(for unit: ReadingUnit) -> some View {
        switch model.presentation {
        case .markdown, .text, .code, .html, .epub, .quickLook:
            MarkdownReaderView(
                state: model.contentState,
                assetBaseURL: model.markdownAssetBaseURL
            )

        case .pdf:
            PDFReaderPane(
                document: model.pdfDocument,
                isLoading: model.isLoadingPDF,
                pageIndex: model.pdfPageIndex,
                onPageChange: model.setPDFPage,
                onLoad: { model.setPresentation(.pdf) }
            )

        case .comparison:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PaneLabel(title: "Markdown", systemImage: "chevron.left.forwardslash.chevron.right")
                    MarkdownReaderView(
                        state: model.contentState,
                        assetBaseURL: model.markdownAssetBaseURL,
                        compact: true
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(spacing: 0) {
                    PaneLabel(title: "原版 PDF", systemImage: "doc.richtext")
                    PDFReaderPane(
                        document: model.pdfDocument,
                        isLoading: model.isLoadingPDF,
                        pageIndex: model.pdfPageIndex,
                        onPageChange: model.setPDFPage,
                        onLoad: { model.setPresentation(.comparison) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ReaderUnitHeader: View {
    @EnvironmentObject private var model: AppModel
    let unit: ReadingUnit

    private var presentationBinding: Binding<PresentationKind> {
        Binding(
            get: { model.presentation },
            set: { presentation in
                model.setPresentation(presentation)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(unit.title)
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                        .textSelection(.enabled)
                    Text(unit.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                if unit.availablePresentations.count > 1 {
                    Picker("呈现方式", selection: presentationBinding) {
                        ForEach(unit.availablePresentations, id: \.self) { presentation in
                            Text(presentation.displayName).tag(presentation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 208)
                    .accessibilityLabel("呈现方式")
                }
            }

            HStack(spacing: 8) {
                ForEach(unit.fragments) { fragment in
                    Button {
                        model.openFragment(fragment)
                    } label: {
                        Label(
                            fragment.label,
                            systemImage: fragment.locator.isPDF ? "doc.richtext" : "link"
                        )
                        .font(.caption)
                        .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("定位到 \(fragment.locator.conciseDescription)")
                }

                Spacer(minLength: 8)

                Label(
                    "置信度 \(Int(unit.confidence * 100))%",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }
}

private struct PaneLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct ReaderNavigationBar: View {
    @EnvironmentObject private var model: AppModel
    let unit: ReadingUnit

    private var isComplete: Bool {
        model.progress.state(for: unit.id) == .completed
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.selectPreviousUnit()
            } label: {
                Label("上一个", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            Text("预计 \(unit.estimatedMinutes) 分钟")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.markCurrentUnitCompleted()
            } label: {
                Label(
                    isComplete ? "已完成，继续" : "完成并继续",
                    systemImage: isComplete ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Button {
                model.selectNextUnit()
            } label: {
                Label("下一个", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

private extension Locator {
    var isPDF: Bool {
        adapterID == "onereader.pdf"
    }
}
