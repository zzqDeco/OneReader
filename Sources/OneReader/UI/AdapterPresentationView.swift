import AppKit
import PDFKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct PresentationSurfaceDescriptor: Identifiable, Hashable, Sendable {
    let id: PresentationSurface
    let supportsTextSelection: Bool
    let supportsStructuredHighlight: Bool
    let supportsFind: Bool
    let limitation: String?
}

struct PresentationRegistry: Sendable {
    static let standard = PresentationRegistry(descriptors: [
        PresentationSurfaceDescriptor(
            id: .pdfKit,
            supportsTextSelection: true,
            supportsStructuredHighlight: true,
            supportsFind: true,
            limitation: nil
        ),
        PresentationSurfaceDescriptor(
            id: .nativeMarkdown,
            supportsTextSelection: true,
            supportsStructuredHighlight: true,
            supportsFind: true,
            limitation: nil
        ),
        PresentationSurfaceDescriptor(
            id: .nativeText,
            supportsTextSelection: true,
            supportsStructuredHighlight: true,
            supportsFind: true,
            limitation: nil
        ),
        PresentationSurfaceDescriptor(
            id: .nativeCode,
            supportsTextSelection: true,
            supportsStructuredHighlight: true,
            supportsFind: true,
            limitation: nil
        ),
        PresentationSurfaceDescriptor(
            id: .sanitizedWeb,
            supportsTextSelection: true,
            supportsStructuredHighlight: true,
            supportsFind: true,
            limitation: "脚本与自动外链已禁用"
        ),
        PresentationSurfaceDescriptor(
            id: .quickLook,
            supportsTextSelection: false,
            supportsStructuredHighlight: false,
            supportsFind: false,
            limitation: "仅支持来源级书签和笔记"
        ),
    ])

    private let descriptors: [PresentationSurface: PresentationSurfaceDescriptor]

    init(descriptors: [PresentationSurfaceDescriptor]) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    func descriptor(for surface: PresentationSurface) -> PresentationSurfaceDescriptor? {
        descriptors[surface]
    }
}

struct AdapterPresentationView: View {
    let document: PresentationDocument

    var body: some View {
        switch document.surface {
        case .pdfKit:
            if let url = document.contentURL {
                ManagedPDFPresentation(url: url, pageIndex: document.locator.pdfPageIndex ?? 0)
            } else {
                unavailable("PDF Snapshot 不可用")
            }
        case .nativeMarkdown:
            NativeTextPresentation(
                content: document.content ?? "",
                isCode: false,
                usesSerif: true
            )
        case .nativeText:
            NativeTextPresentation(
                content: document.content ?? "",
                isCode: false,
                usesSerif: true
            )
        case .nativeCode:
            NativeTextPresentation(
                content: document.content ?? "",
                isCode: true,
                usesSerif: false
            )
        case .sanitizedWeb:
            ControlledWebPresentation(document: document)
        case .quickLook:
            if let url = document.contentURL {
                ManagedQuickLookPresentation(url: url)
            } else {
                unavailable("Quick Look Snapshot 不可用")
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            "无法呈现",
            systemImage: "doc.questionmark",
            description: Text(message)
        )
    }
}

private struct NativeTextPresentation: View {
    let content: String
    let isCode: Bool
    let usesSerif: Bool

    var body: some View {
        ScrollView {
            Text(content)
                .font(
                    isCode
                        ? .system(size: 13, design: .monospaced)
                        : .system(size: 17, design: usesSerif ? .serif : .default)
                )
                .lineSpacing(isCode ? 3 : 7)
                .textSelection(.enabled)
                .frame(maxWidth: isCode ? .infinity : 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .accessibilityLabel(isCode ? "代码阅读内容" : "文本阅读内容")
    }
}

private struct ManagedPDFPresentation: NSViewRepresentable {
    let url: URL
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let page = view.document?.page(at: pageIndex), view.currentPage !== page {
            view.go(to: page)
        }
    }
}

private struct ManagedQuickLookPresentation: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.autostarts = true
        return view ?? QLPreviewView(frame: .zero, style: .compact)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

private struct ControlledWebPresentation: NSViewRepresentable {
    let document: PresentationDocument

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let root = document.baseURL {
            configuration.setURLSchemeHandler(
                ReadOnlyContentSchemeHandler(rootURL: root),
                forURLScheme: "onereader-content"
            )
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedDocumentID != document.id else { return }
        context.coordinator.loadedDocumentID = document.id
        let baseURL = URL(
            string: "onereader-content://\(document.locator.snapshotID)/"
        )
        view.loadHTMLString(document.content ?? "", baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedDocumentID: String?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let allowed = navigationAction.navigationType == .other
                && (url.scheme == "about" || url.scheme == "onereader-content")
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

private final class ReadOnlyContentSchemeHandler: NSObject, WKURLSchemeHandler,
    @unchecked Sendable
{
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: 400)
            return
        }
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relativePath = rawPath.split(separator: "/").map(String.init).joined(separator: "/")
        guard !relativePath.split(separator: "/").contains("..") else {
            fail(urlSchemeTask, code: 403)
            return
        }
        let requested = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard requested.pathComponents.starts(with: rootURL.pathComponents),
              let values = try? requested.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? Data(contentsOf: requested, options: [.mappedIfSafe]) else {
            fail(urlSchemeTask, code: 404)
            return
        }
        let mediaType = UTType(filenameExtension: requested.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: requestURL,
            mimeType: mediaType,
            expectedContentLength: data.count,
            textEncodingName: mediaType.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(
            NSError(
                domain: "OneReader.ReadOnlyContent",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "只读内容不可用"]
            )
        )
    }
}
