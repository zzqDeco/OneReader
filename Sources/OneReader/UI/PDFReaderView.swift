import PDFKit
import SwiftUI

struct PDFReaderPane: View {
    let document: PDFDocument?
    let isLoading: Bool
    let pageIndex: Int
    let onPageChange: (Int) -> Void
    let onLoad: () -> Void

    var body: some View {
        if let document {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        onPageChange(pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(pageIndex <= 0)
                    .help("上一页")

                    Text("\(pageIndex + 1) / \(document.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        onPageChange(pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(pageIndex + 1 >= document.pageCount)
                    .help("下一页")

                    Spacer()

                    Label("PDFKit 原生视图", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar)

                Divider()

                PDFKitView(
                    document: document,
                    pageIndex: pageIndex,
                    onPageChange: onPageChange
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在载入原版 PDF…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(ReaderTheme.orange)
                    Text("PDF 尚未载入")
                        .font(.headline)
                    Text("首次打开会从公开仓库读取约 2 MB，之后交给 PDFKit 原生渲染。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("载入 PDF", action: onLoad)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ReaderTheme.paper)
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = FlexiblePDFView()
        view.document = document
        view.autoScales = true
        // Keep PDFKit on one native page at a time. Continuous mode eagerly
        // exposes hundreds of page views to AppKit accessibility and makes a
        // 300-page document unnecessarily expensive in a split reader.
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .windowBackgroundColor
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(to: view)
        goToPage(pageIndex, in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        guard
            let current = view.currentPage,
            view.document?.index(for: current) != pageIndex
        else {
            return
        }
        goToPage(pageIndex, in: view)
    }

    private func goToPage(_ pageIndex: Int, in view: PDFView) {
        guard
            let document = view.document,
            pageIndex >= 0,
            pageIndex < document.pageCount,
            let page = document.page(at: pageIndex)
        else {
            return
        }
        view.go(to: page)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void
        private weak var view: PDFView?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func attach(to view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc
        private func pageDidChange() {
            guard
                let view,
                let document = view.document,
                let page = view.currentPage
            else {
                return
            }
            let index = document.index(for: page)
            if index >= 0 {
                onPageChange(index)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class FlexiblePDFView: PDFView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric
        )
    }
}
