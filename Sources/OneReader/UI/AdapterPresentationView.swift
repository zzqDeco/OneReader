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
            limitation: "来源脚本、自动外链与跨来源资源读取已禁用"
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
    @Environment(\.colorScheme) private var colorScheme

    let document: PresentationDocument
    let preferences: ReaderPreferences
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

    var body: some View {
        Group {
            switch document.surface {
            case .pdfKit:
                if let url = document.contentURL {
                    ManagedPDFPresentation(
                        url: url,
                        documentLocator: document.locator,
                        pageIndex: document.locator.pdfPageIndex ?? 0,
                        scale: preferences.pdfScale,
                        onSelectionChange: onSelectionChange,
                        onPositionChange: onPositionChange
                    )
                } else {
                    unavailable("PDF Snapshot 不可用")
                }
            case .nativeMarkdown:
                nativePresentation(kind: .markdown)
            case .nativeText:
                nativePresentation(kind: .text)
            case .nativeCode:
                nativePresentation(kind: .code)
            case .sanitizedWeb:
                ControlledWebPresentation(
                    document: document,
                    preferences: preferences,
                    colorScheme: resolvedColorScheme,
                    onSelectionChange: onSelectionChange,
                    onPositionChange: onPositionChange
                )
            case .quickLook:
                if let url = document.contentURL {
                    ManagedQuickLookPresentation(url: url)
                        .onAppear {
                            onSelectionChange(nil)
                            onPositionChange(document.locator)
                        }
                } else {
                    unavailable("Quick Look Snapshot 不可用")
                }
            }
        }
        .background(backgroundColor)
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.theme {
        case .system: nil
        case .paper: .light
        case .dark: .dark
        }
    }

    private var resolvedColorScheme: ColorScheme {
        preferredColorScheme ?? colorScheme
    }

    private var backgroundColor: Color {
        switch preferences.theme {
        case .system: Color(nsColor: .textBackgroundColor)
        case .paper: Color(red: 0.97, green: 0.95, blue: 0.90)
        case .dark: Color(red: 0.08, green: 0.09, blue: 0.10)
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            "无法呈现",
            systemImage: "doc.questionmark",
            description: Text(message)
        )
    }

    @ViewBuilder
    private func nativePresentation(kind: NativeTextPresentationKind) -> some View {
        let presentation = NativeSelectableTextPresentation(
            content: document.content ?? "",
            locator: document.locator,
            kind: kind,
            preferences: preferences,
            onSelectionChange: onSelectionChange,
            onPositionChange: onPositionChange
        )
        if kind == .code {
            presentation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                presentation
                    .frame(maxWidth: preferences.lineWidth + 56, maxHeight: .infinity)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private enum NativeTextPresentationKind: String {
    case markdown
    case text
    case code
}

private struct NativeSelectableTextPresentation: NSViewRepresentable {
    let content: String
    let locator: Locator
    let kind: NativeTextPresentationKind
    let preferences: ReaderPreferences
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

    private var isCode: Bool { kind == .code }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReaderTextScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = isCode
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let initialWidth = isCode ? 900 : preferences.lineWidth + 56
        let textView = ReaderTextView(
            frame: NSRect(x: 0, y: 0, width: initialWidth, height: 1)
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = kind == .markdown
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.widthTracksTextView = !isCode
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = isCode
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(isCode ? "代码阅读内容" : "文本阅读内容")
        scrollView.documentView = textView
        context.coordinator.observe(textView, clipView: scrollView.contentView)
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ReaderTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: ReaderTextView) {
        let signature = [
            kind.rawValue,
            AdapterUtilities.sha256(content),
            String(preferences.fontSize),
            String(preferences.lineSpacing),
            preferences.theme.rawValue,
        ].joined(separator: ":")
        if textView.renderSignature != signature {
            textView.renderSignature = signature

            let font = isCode
                ? NSFont.monospacedSystemFont(ofSize: preferences.fontSize - 2, weight: .regular)
                : NSFont.systemFont(ofSize: preferences.fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = preferences.lineSpacing
            paragraph.maximumLineHeight = font.pointSize + preferences.lineSpacing + 4
            let rendered: NSAttributedString
            if kind == .markdown {
                var renderer = NativeMarkdownRenderer(
                    fontSize: preferences.fontSize,
                    lineSpacing: preferences.lineSpacing
                )
                rendered = renderer.render(content)
            } else {
                rendered = NSAttributedString(
                    string: content,
                    attributes: [
                        .font: font,
                        .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
            }
            textView.textStorage?.setAttributedString(rendered)
            if kind != .markdown {
                textView.font = font
                textView.defaultParagraphStyle = paragraph
                textView.textColor = .labelColor
            }
            textView.backgroundColor = .clear
            textView.anchorSignature = nil
        }
        applyAnchor(to: textView)
    }

    private func applyAnchor(to textView: ReaderTextView) {
        let anchorSignature = [
            locator.stableID,
            locator.textQuote?.prefix ?? "",
            locator.textQuote?.exact ?? "",
            locator.textQuote?.suffix ?? "",
            locator.fingerprint ?? "",
        ].joined(separator: ":")
        guard textView.anchorSignature != anchorSignature else { return }
        textView.anchorSignature = anchorSignature

        let value = textView.string as NSString
        let targetRange: NSRange
        if kind == .markdown,
           let start = locator.payload["startUTF16"].flatMap(Int.init),
           let end = locator.payload["endUTF16"].flatMap(Int.init),
           let storage = textView.textStorage,
           let mapped = MarkdownSourceMap.renderedRange(
               forSourceRange: NSRange(location: start, length: max(0, end - start)),
               in: storage
           ) {
            targetRange = mapped
        } else if let quote = locator.textQuote,
           let quoteRange = Self.range(of: quote, in: value) {
            targetRange = quoteRange
        } else if let startValue = locator.payload[
            kind == .markdown ? "renderedStartUTF16" : "startUTF16"
        ],
                  let start = Int(startValue),
                  start >= 0,
                  start <= value.length {
            let end = kind == .markdown
                ? start
                : min(
                    max(start, Int(locator.payload["endUTF16"] ?? "") ?? start),
                    value.length
                )
            targetRange = NSRange(location: start, length: end - start)
        } else {
            targetRange = NSRange(location: 0, length: 0)
        }

        textView.isApplyingAnchor = true
        textView.setSelectedRange(targetRange)
        if targetRange.location > 0 || targetRange.length > 0 {
            textView.scrollRangeToVisible(targetRange)
        }
        DispatchQueue.main.async {
            textView.isApplyingAnchor = false
        }
    }

    private static func range(of quote: TextQuote, in value: NSString) -> NSRange? {
        guard !quote.exact.isEmpty else { return nil }
        let whole = NSRange(location: 0, length: value.length)
        var searchRange = whole
        while searchRange.length > 0 {
            let match = value.range(of: quote.exact, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }

            let prefixMatches = quote.prefix.map { prefix in
                let length = min((prefix as NSString).length, match.location)
                let candidate = value.substring(
                    with: NSRange(location: match.location - length, length: length)
                )
                return candidate.hasSuffix(prefix)
            } ?? true
            let suffixMatches = quote.suffix.map { suffix in
                let suffixStart = NSMaxRange(match)
                let length = min((suffix as NSString).length, value.length - suffixStart)
                let candidate = value.substring(
                    with: NSRange(location: suffixStart, length: length)
                )
                return candidate.hasPrefix(suffix)
            } ?? true
            if prefixMatches && suffixMatches { return match }

            let next = NSMaxRange(match)
            guard next < value.length else { break }
            searchRange = NSRange(location: next, length: value.length - next)
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeSelectableTextPresentation
        private weak var observedTextView: ReaderTextView?
        private var lastPositionSignature: String?

        init(parent: NativeSelectableTextPresentation) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(_ textView: ReaderTextView, clipView: NSClipView) {
            observedTextView = textView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: textView,
            )
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ReaderTextView,
                  !textView.isApplyingAnchor else { return }
            publishSelection(from: textView)
        }

        @objc private func visibleBoundsDidChange(_ notification: Notification) {
            guard let textView = observedTextView,
                  !textView.isApplyingAnchor else { return }
            publishPosition(from: textView)
        }

        private func publishSelection(from textView: NSTextView) {
            let range = textView.selectedRange()
            let value = textView.string as NSString
            guard range.length > 0, NSMaxRange(range) <= value.length else {
                parent.onSelectionChange(nil)
                return
            }
            let selected = value.substring(with: range)
            var payload = parent.locator.payload
            for key in [
                "startUTF16", "endUTF16", "startLine", "endLine",
                "renderedStartUTF16",
            ] {
                payload[key] = nil
            }
            let sourceValue = parent.content as NSString
            let sourceRange: NSRange
            if parent.kind == .markdown {
                guard let storage = textView.textStorage,
                      let mapped = MarkdownSourceMap.sourceRange(
                          forRenderedRange: range,
                          in: storage
                      ) else {
                    parent.onSelectionChange(nil)
                    return
                }
                sourceRange = mapped
                payload["renderedStartUTF16"] = String(range.location)
            } else {
                sourceRange = range
            }
            let locatorQuote: TextQuote
            let locatorFingerprint: String
            if sourceRange.location != NSNotFound,
               NSMaxRange(sourceRange) <= sourceValue.length {
                let sourcePrefix = sourceValue.substring(to: sourceRange.location)
                let sourceExact = sourceValue.substring(with: sourceRange)
                let startLine = sourcePrefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                let lineCount = sourceExact.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                payload["startUTF16"] = String(sourceRange.location)
                payload["endUTF16"] = String(NSMaxRange(sourceRange))
                payload["startLine"] = String(startLine)
                payload["endLine"] = String(startLine + lineCount)
                let sourcePrefixRange = NSRange(
                    location: max(0, sourceRange.location - 48),
                    length: min(48, sourceRange.location)
                )
                let sourceRemaining = sourceValue.length - NSMaxRange(sourceRange)
                let sourceSuffixRange = NSRange(
                    location: NSMaxRange(sourceRange),
                    length: min(48, sourceRemaining)
                )
                let prefix = quoteContext(in: sourceValue, range: sourcePrefixRange)
                let suffix = quoteContext(in: sourceValue, range: sourceSuffixRange)
                locatorQuote = TextQuote(
                    prefix: prefix.isEmpty ? nil : prefix,
                    exact: sourceExact,
                    suffix: suffix.isEmpty ? nil : suffix
                )
                locatorFingerprint = AdapterUtilities.sha256(sourceExact)
            } else {
                parent.onSelectionChange(nil)
                return
            }
            let locator = Locator(
                sourceID: parent.locator.sourceID,
                snapshotID: parent.locator.snapshotID,
                adapterID: parent.locator.adapterID,
                payload: payload,
                structuralPath: parent.locator.structuralPath,
                textQuote: locatorQuote,
                fingerprint: locatorFingerprint
            )
            parent.onSelectionChange(ReaderSelection(text: selected, locator: locator))
        }

        private func publishPosition(from textView: ReaderTextView) {
            let value = textView.string as NSString
            guard value.length > 0 else { return }
            let visible = textView.visibleRect
            let point = NSPoint(
                x: textView.textContainerOrigin.x + 2,
                y: max(textView.textContainerOrigin.y, visible.minY + 2)
            )
            let start = min(max(0, textView.characterIndexForInsertion(at: point)), value.length)
            let exactLength = min(96, value.length - start)
            let rawRange = NSRange(location: start, length: exactLength)
            let exactRange = value.rangeOfComposedCharacterSequences(for: rawRange)
            let exact = value.substring(with: exactRange)
            guard !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let prefixLength = min(48, exactRange.location)
            let suffixStart = NSMaxRange(exactRange)
            let suffixLength = min(48, value.length - suffixStart)
            let prefix = quoteContext(
                in: value,
                range: NSRange(location: exactRange.location - prefixLength, length: prefixLength)
            )
            let suffix = quoteContext(
                in: value,
                range: NSRange(location: suffixStart, length: suffixLength)
            )
            var payload = parent.locator.payload
            let locatorQuote: TextQuote
            let locatorFingerprint: String
            if parent.kind == .markdown {
                guard let storage = textView.textStorage,
                      let sourceRange = MarkdownSourceMap.sourceRange(
                          forRenderedRange: exactRange,
                          in: storage
                      ) else { return }
                let source = parent.content as NSString
                guard NSMaxRange(sourceRange) <= source.length else { return }
                let sourceExact = source.substring(with: sourceRange)
                let sourcePrefixLength = min(48, sourceRange.location)
                let sourceSuffixStart = NSMaxRange(sourceRange)
                let sourceSuffixLength = min(48, source.length - sourceSuffixStart)
                let sourcePrefix = quoteContext(
                    in: source,
                    range: NSRange(
                        location: sourceRange.location - sourcePrefixLength,
                        length: sourcePrefixLength
                    )
                )
                let sourceSuffix = quoteContext(
                    in: source,
                    range: NSRange(location: sourceSuffixStart, length: sourceSuffixLength)
                )
                payload["renderedStartUTF16"] = String(exactRange.location)
                payload["startUTF16"] = String(sourceRange.location)
                payload["endUTF16"] = String(NSMaxRange(sourceRange))
                let textBefore = source.substring(to: sourceRange.location)
                payload["startLine"] = String(
                    textBefore.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                )
                locatorQuote = TextQuote(
                    prefix: sourcePrefix.isEmpty ? nil : sourcePrefix,
                    exact: sourceExact,
                    suffix: sourceSuffix.isEmpty ? nil : sourceSuffix
                )
                locatorFingerprint = AdapterUtilities.sha256(sourceExact)
            } else {
                payload["startUTF16"] = String(exactRange.location)
                payload["endUTF16"] = String(NSMaxRange(exactRange))
                let textBefore = value.substring(to: exactRange.location)
                let startLine = textBefore.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                payload["startLine"] = String(startLine)
                locatorQuote = TextQuote(
                    prefix: prefix.isEmpty ? nil : prefix,
                    exact: exact,
                    suffix: suffix.isEmpty ? nil : suffix
                )
                locatorFingerprint = AdapterUtilities.sha256(exact)
            }
            let locator = Locator(
                sourceID: parent.locator.sourceID,
                snapshotID: parent.locator.snapshotID,
                adapterID: parent.locator.adapterID,
                payload: payload,
                structuralPath: parent.locator.structuralPath,
                textQuote: locatorQuote,
                fingerprint: locatorFingerprint
            )
            let signature = AdapterUtilities.sha256(
                "\(locator.payload)|\(exact)|\(prefix)|\(suffix)"
            )
            guard signature != lastPositionSignature else { return }
            lastPositionSignature = signature
            parent.onPositionChange(locator)
        }

        private func quoteContext(in value: NSString, range: NSRange) -> String {
            guard range.length > 0 else { return "" }
            let composed = value.rangeOfComposedCharacterSequences(for: range)
            return value.substring(with: composed)
        }
    }
}

private final class ReaderTextView: NSTextView {
    var renderSignature: String?
    var anchorSignature: String?
    var isApplyingAnchor = false
}

private final class ReaderTextScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct ManagedPDFPresentation: NSViewRepresentable {
    let url: URL
    let documentLocator: Locator
    let pageIndex: Int
    let scale: Double
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.loadedURL = url
            context.coordinator.appliedAnchorSignature = nil
        }
        view.scaleFactor = min(max(scale, 0.5), 3)
        let anchorSignature = [
            documentLocator.stableID,
            documentLocator.textQuote?.exact ?? "",
            documentLocator.payload["rect"] ?? "",
        ].joined(separator: ":")
        if context.coordinator.appliedAnchorSignature != anchorSignature,
           let page = view.document?.page(at: pageIndex) {
            context.coordinator.isApplyingAnchor = true
            context.coordinator.appliedAnchorSignature = anchorSignature
            if let exact = documentLocator.textQuote?.exact,
               let pageText = page.string,
               let range = pageText.range(of: exact),
               let selection = page.selection(
                   for: NSRange(range, in: pageText)
               ) {
                view.setCurrentSelection(selection, animate: false)
                view.go(to: selection)
            } else {
                view.go(to: page)
            }
            DispatchQueue.main.async {
                context.coordinator.isApplyingAnchor = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ManagedPDFPresentation
        var loadedURL: URL?
        var appliedAnchorSignature: String?
        var isApplyingAnchor = false

        init(parent: ManagedPDFPresentation) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: .PDFViewSelectionChanged,
                object: view,
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            publishSelection(from: view)
        }

        @objc private func pageDidChange(_ notification: Notification) {
            guard !isApplyingAnchor,
                  let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let document = view.document else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return }
            var payload = parent.documentLocator.payload
            payload["pageIndex"] = String(pageIndex)
            payload["rect"] = nil
            parent.onPositionChange(
                Locator(
                    sourceID: parent.documentLocator.sourceID,
                    snapshotID: parent.documentLocator.snapshotID,
                    adapterID: parent.documentLocator.adapterID,
                    payload: payload,
                    structuralPath: "page/\(pageIndex)",
                    textQuote: nil,
                    fingerprint: nil
                )
            )
        }

        private func publishSelection(from view: PDFView) {
            guard let selection = view.currentSelection,
                  let selected = selection.string,
                  !selected.isEmpty,
                  let page = selection.pages.first,
                  let document = view.document else {
                parent.onSelectionChange(nil)
                return
            }
            let pageIndex = document.index(for: page)
            let rect = selection.bounds(for: page)
            var payload = parent.documentLocator.payload
            payload["pageIndex"] = String(pageIndex)
            payload["rect"] = [rect.minX, rect.minY, rect.width, rect.height]
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            let locator = Locator(
                sourceID: parent.documentLocator.sourceID,
                snapshotID: parent.documentLocator.snapshotID,
                adapterID: parent.documentLocator.adapterID,
                payload: payload,
                structuralPath: "page/\(pageIndex)",
                textQuote: TextQuote(prefix: nil, exact: selected, suffix: nil),
                fingerprint: AdapterUtilities.sha256(selected)
            )
            parent.onSelectionChange(ReaderSelection(text: selected, locator: locator))
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
    let preferences: ReaderPreferences
    let colorScheme: ColorScheme
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.selectionHandlerName
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.positionHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.selectionBridge,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.positionBridge,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
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
        context.coordinator.parent = self
        let renderID = [
            AdapterUtilities.sha256(document.content ?? ""),
            String(describing: preferences),
            colorScheme == .dark ? "dark" : "light",
            document.baseURL?.standardizedFileURL.path ?? "",
        ].joined(separator: ":")
        let anchorID = Self.anchorSignature(document.locator)
        guard context.coordinator.loadedDocumentID != renderID else {
            context.coordinator.applyAnchor(anchorID, in: view)
            return
        }
        context.coordinator.loadedDocumentID = renderID
        context.coordinator.pendingAnchorID = anchorID
        context.coordinator.appliedAnchorID = nil
        let baseURL = URL(string: "onereader-content://\(document.locator.snapshotID)/")
        view.loadHTMLString(styledHTML, baseURL: baseURL)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.selectionHandlerName
        )
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.positionHandlerName
        )
    }

    private var styledHTML: String {
        let isDark = colorScheme == .dark
        let foreground = isDark ? "#e8e6e3" : "#25231f"
        let background = isDark ? "#141619" : "#f8f3e8"
        let style = """
            <style id="onereader-reader-theme">
            :root { color-scheme: \(isDark ? "dark" : "light"); }
            body { color: \(foreground); background: \(background); font: \(preferences.fontSize)px/\(1.45 + preferences.lineSpacing / 30) ui-serif, Georgia, serif; max-width: \(preferences.lineWidth)px; margin: 0 auto; padding: 32px 34px 80px; }
            img, svg, video { max-width: 100%; height: auto; }
            pre, code { font-family: ui-monospace, SFMono-Regular, monospace; }
            a { color: #087f8c; }
            ::selection { background: rgba(239, 168, 68, .34); }
            </style>
            """
        let html = document.content ?? ""
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: range, with: style + "</head>")
        }
        return style + html
    }

    private static func anchorSignature(_ locator: Locator) -> String {
        AdapterUtilities.sha256([
            locator.stableID,
            locator.structuralPath ?? "",
            locator.textQuote?.prefix ?? "",
            locator.textQuote?.exact ?? "",
            locator.textQuote?.suffix ?? "",
            locator.fingerprint ?? "",
        ].joined(separator: ":"))
    }

    private static func anchorScript(for locator: Locator) -> String {
        let selector = locator.payload["domPath"].flatMap { $0.isEmpty ? nil : $0 }
            ?? locator.structuralPath.flatMap { $0.hasPrefix("body") ? $0 : nil }
        let quote = locator.textQuote?.exact
        return """
            (() => {
              const selector = \(javaScriptLiteral(selector));
              const quote = \(javaScriptLiteral(quote));
              const selection = window.getSelection();
              if (!selector && !quote) {
                window.__oneReaderApplyingAnchor = true;
                if (selection) selection.removeAllRanges();
                window.scrollTo({ top: 0, behavior: 'auto' });
                requestAnimationFrame(() => { window.__oneReaderApplyingAnchor = false; });
                return true;
              }
              let target = null;
              if (selector) {
                try { target = document.querySelector(selector); } catch (_) {}
              }
              function matchingTextNode(root, needle) {
                if (!root || !needle) return null;
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                  if ((node.nodeValue || '').includes(needle)) return node;
                }
                return null;
              }
              let textNode = matchingTextNode(target || document.body, quote);
              if (!textNode && target) textNode = matchingTextNode(document.body, quote);
              if (!target && textNode) target = textNode.parentElement;
              if (!target) return false;
              window.__oneReaderApplyingAnchor = true;
              if (selection) selection.removeAllRanges();
              if (selection && textNode && quote) {
                const offset = (textNode.nodeValue || '').indexOf(quote);
                if (offset >= 0) {
                  const range = document.createRange();
                  range.setStart(textNode, offset);
                  range.setEnd(textNode, offset + quote.length);
                  selection.addRange(range);
                }
              }
              target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
              requestAnimationFrame(() => { window.__oneReaderApplyingAnchor = false; });
              return true;
            })();
            """
    }

    private static func javaScriptLiteral(_ value: String?) -> String {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "null" }
        return literal
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let selectionHandlerName = "oneReaderSelection"
        static let positionHandlerName = "oneReaderPosition"
        // This host-owned bridge observes selection only. Source JavaScript stays disabled.
        static let selectionBridge = """
            (() => {
              function pathFor(node) {
                const parts = [];
                let element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
                while (element && element !== document.body) {
                  let index = 1;
                  let sibling = element.previousElementSibling;
                  while (sibling) { if (sibling.tagName === element.tagName) index++; sibling = sibling.previousElementSibling; }
                  parts.unshift(element.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
                  element = element.parentElement;
                }
                return 'body > ' + parts.join(' > ');
              }
              document.addEventListener('selectionchange', () => {
                if (window.__oneReaderApplyingAnchor) return;
                const selection = window.getSelection();
                const text = selection ? selection.toString() : '';
                const path = selection && selection.rangeCount ? pathFor(selection.getRangeAt(0).startContainer) : '';
                window.webkit.messageHandlers.oneReaderSelection.postMessage({ text, path });
              }, { passive: true });
            })();
            """
        static let positionBridge = """
            (() => {
              function pathFor(node) {
                const parts = [];
                let element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
                while (element && element !== document.body) {
                  let index = 1;
                  let sibling = element.previousElementSibling;
                  while (sibling) { if (sibling.tagName === element.tagName) index++; sibling = sibling.previousElementSibling; }
                  parts.unshift(element.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
                  element = element.parentElement;
                }
                return 'body > ' + parts.join(' > ');
              }
              function firstText(root) {
                if (!root) return '';
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                  const value = (node.nodeValue || '').replace(/\\s+/g, ' ').trim();
                  if (value) return value.slice(0, 96);
                }
                return '';
              }
              function publish() {
                if (window.__oneReaderApplyingAnchor) return;
                const element = document.elementFromPoint(Math.max(1, window.innerWidth / 2), Math.min(96, Math.max(1, window.innerHeight / 4))) || document.body;
                window.webkit.messageHandlers.oneReaderPosition.postMessage({
                  path: pathFor(element),
                  quote: firstText(element)
                });
              }
              let timer = 0;
              document.addEventListener('scroll', () => {
                clearTimeout(timer);
                timer = setTimeout(publish, 180);
              }, { passive: true, capture: true });
              setTimeout(publish, 0);
            })();
            """

        var parent: ControlledWebPresentation
        var loadedDocumentID: String?
        var pendingAnchorID: String?
        var appliedAnchorID: String?

        init(parent: ControlledWebPresentation) {
            self.parent = parent
        }

        @MainActor
        func applyAnchor(_ anchorID: String, in webView: WKWebView) {
            guard appliedAnchorID != anchorID else { return }
            pendingAnchorID = anchorID
            guard !webView.isLoading else { return }
            appliedAnchorID = anchorID
            pendingAnchorID = nil
            webView.evaluateJavaScript(
                ControlledWebPresentation.anchorScript(for: parent.document.locator)
            )
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let anchorID = pendingAnchorID
                ?? ControlledWebPresentation.anchorSignature(parent.document.locator)
            applyAnchor(anchorID, in: webView)
        }

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

        @MainActor
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            if message.name == Self.positionHandlerName {
                let path = body["path"] as? String
                let quote = (body["quote"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var payload = parent.document.locator.payload
                if let path, !path.isEmpty { payload["domPath"] = path }
                parent.onPositionChange(
                    Locator(
                        sourceID: parent.document.locator.sourceID,
                        snapshotID: parent.document.locator.snapshotID,
                        adapterID: parent.document.locator.adapterID,
                        payload: payload,
                        structuralPath: path ?? parent.document.locator.structuralPath,
                        textQuote: quote.flatMap { value in
                            value.isEmpty ? nil : TextQuote(prefix: nil, exact: value, suffix: nil)
                        },
                        fingerprint: quote.flatMap { value in
                            value.isEmpty ? nil : AdapterUtilities.sha256(value)
                        }
                    )
                )
                return
            }
            guard message.name == Self.selectionHandlerName,
                  let text = body["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                parent.onSelectionChange(nil)
                return
            }
            let path = body["path"] as? String
            var payload = parent.document.locator.payload
            if let path, !path.isEmpty { payload["domPath"] = path }
            let locator = Locator(
                sourceID: parent.document.locator.sourceID,
                snapshotID: parent.document.locator.snapshotID,
                adapterID: parent.document.locator.adapterID,
                payload: payload,
                structuralPath: path ?? parent.document.locator.structuralPath,
                textQuote: TextQuote(prefix: nil, exact: text, suffix: nil),
                fingerprint: AdapterUtilities.sha256(text)
            )
            parent.onSelectionChange(ReaderSelection(text: text, locator: locator))
        }
    }
}

enum ReadOnlyContentResourceError: Error, Equatable {
    case invalidPath
    case missingFile
    case symbolicLink
    case unsupportedMediaType
    case resourceTooLarge
    case cancelled
}

struct ReadOnlyContentResource: Equatable, Sendable {
    let fileURL: URL
    let mediaType: String
    let byteCount: Int64
}

struct ReadOnlyContentResourceLoader: Sendable {
    static let maximumResourceBytes: Int64 = 32 * 1_024 * 1_024
    static let defaultChunkBytes = 256 * 1_024

    let rootURL: URL
    let maximumResourceBytes: Int64

    init(
        rootURL: URL,
        maximumResourceBytes: Int64 = Self.maximumResourceBytes
    ) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumResourceBytes = maximumResourceBytes
    }

    func resolve(requestURL: URL) throws -> ReadOnlyContentResource {
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let components = rawPath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains(".") else {
            throw ReadOnlyContentResourceError.invalidPath
        }
        let requested = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        guard requested.pathComponents.starts(with: rootURL.pathComponents) else {
            throw ReadOnlyContentResourceError.invalidPath
        }
        let resolved = requested.resolvingSymlinksInPath()
        guard resolved == requested else {
            throw ReadOnlyContentResourceError.symbolicLink
        }
        guard resolved.pathComponents.starts(with: rootURL.pathComponents),
              let values = try? resolved.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true else {
            throw ReadOnlyContentResourceError.missingFile
        }
        guard values.isSymbolicLink != true else {
            throw ReadOnlyContentResourceError.symbolicLink
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount <= maximumResourceBytes else {
            throw ReadOnlyContentResourceError.resourceTooLarge
        }
        guard let mediaType = Self.allowedMediaType(for: resolved) else {
            throw ReadOnlyContentResourceError.unsupportedMediaType
        }
        return ReadOnlyContentResource(
            fileURL: resolved,
            mediaType: mediaType,
            byteCount: byteCount
        )
    }

    func stream(
        _ resource: ReadOnlyContentResource,
        chunkBytes: Int = Self.defaultChunkBytes,
        isCancelled: () -> Bool,
        receive: (Data) throws -> Void
    ) throws {
        guard chunkBytes > 0 else { throw ReadOnlyContentResourceError.invalidPath }
        let handle = try FileHandle(forReadingFrom: resource.fileURL)
        defer { try? handle.close() }
        var delivered: Int64 = 0
        while delivered < resource.byteCount {
            guard !isCancelled() else { throw ReadOnlyContentResourceError.cancelled }
            let remaining = resource.byteCount - delivered
            let count = min(chunkBytes, Int(remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
            delivered += Int64(data.count)
            guard delivered <= maximumResourceBytes else {
                throw ReadOnlyContentResourceError.resourceTooLarge
            }
            try receive(data)
        }
        guard !isCancelled() else { throw ReadOnlyContentResourceError.cancelled }
    }

    private static func allowedMediaType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mediaType = type.preferredMIMEType else { return nil }
        let exact: Set<String> = [
            "text/css", "text/html", "application/xhtml+xml",
            "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
            "image/avif", "image/bmp", "image/x-icon",
            "font/woff", "font/woff2", "font/ttf", "font/otf",
            "application/font-woff", "application/vnd.ms-fontobject",
            "audio/mpeg", "audio/mp4", "audio/ogg", "audio/wav",
            "video/mp4", "video/webm", "video/ogg",
        ]
        return exact.contains(mediaType) ? mediaType : nil
    }
}

final class ReadOnlySchemeTaskLifecycle: @unchecked Sendable {
    private enum State { case active, stopped, terminal }

    private let condition = NSCondition()
    private var state = State.active
    private var activeCallbacks = 0

    var isStopped: Bool {
        condition.withLock { state != .active }
    }

    @discardableResult
    func performIfActive(_ callback: () -> Void) -> Bool {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            return false
        }
        activeCallbacks += 1
        condition.unlock()
        callback()
        condition.lock()
        activeCallbacks -= 1
        if activeCallbacks == 0 { condition.broadcast() }
        condition.unlock()
        return true
    }

    @discardableResult
    func finishIfActive(_ callback: () -> Void) -> Bool {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            return false
        }
        state = .terminal
        activeCallbacks += 1
        condition.unlock()
        callback()
        condition.lock()
        activeCallbacks -= 1
        if activeCallbacks == 0 { condition.broadcast() }
        condition.unlock()
        return true
    }

    func stop() {
        condition.lock()
        if state == .active { state = .stopped }
        while activeCallbacks > 0 { condition.wait() }
        condition.unlock()
    }
}

private final class ReadOnlyContentSchemeHandler: NSObject, WKURLSchemeHandler,
    @unchecked Sendable
{

    private final class SchemeTaskBox: @unchecked Sendable {
        let task: WKURLSchemeTask
        init(_ task: WKURLSchemeTask) { self.task = task }
    }

    private final class TokenStore: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [ObjectIdentifier: ReadOnlySchemeTaskLifecycle] = [:]

        func insert(_ token: ReadOnlySchemeTaskLifecycle, for key: ObjectIdentifier) {
            lock.withLock { tokens[key] = token }
        }

        func remove(for key: ObjectIdentifier) -> ReadOnlySchemeTaskLifecycle? {
            lock.withLock { tokens.removeValue(forKey: key) }
        }
    }

    private let loader: ReadOnlyContentResourceLoader
    private let queue = DispatchQueue(
        label: "com.onereader.read-only-content",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let tokenStore = TokenStore()

    init(rootURL: URL) {
        loader = ReadOnlyContentResourceLoader(rootURL: rootURL)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            Self.fail(urlSchemeTask, code: 400)
            return
        }
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        let lifecycle = ReadOnlySchemeTaskLifecycle()
        tokenStore.insert(lifecycle, for: key)
        let taskBox = SchemeTaskBox(urlSchemeTask)
        queue.async { [loader, tokenStore] in
            defer { _ = tokenStore.remove(for: key) }
            do {
                let resource = try loader.resolve(requestURL: requestURL)
                let response = URLResponse(
                    url: requestURL,
                    mimeType: resource.mediaType,
                    expectedContentLength: Int(resource.byteCount),
                    textEncodingName: resource.mediaType.hasPrefix("text/") ? "utf-8" : nil
                )
                guard lifecycle.performIfActive({ taskBox.task.didReceive(response) }) else {
                    return
                }
                try loader.stream(
                    resource,
                    isCancelled: { lifecycle.isStopped },
                    receive: { data in
                        guard lifecycle.performIfActive({ taskBox.task.didReceive(data) }) else {
                            throw ReadOnlyContentResourceError.cancelled
                        }
                    }
                )
                _ = lifecycle.finishIfActive { taskBox.task.didFinish() }
            } catch ReadOnlyContentResourceError.cancelled {
                return
            } catch let error as ReadOnlyContentResourceError {
                _ = lifecycle.finishIfActive {
                    Self.fail(taskBox.task, code: Self.statusCode(for: error))
                }
            } catch {
                _ = lifecycle.finishIfActive { Self.fail(taskBox.task, code: 500) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        tokenStore.remove(for: key)?.stop()
    }

    nonisolated private static func statusCode(
        for error: ReadOnlyContentResourceError
    ) -> Int {
        switch error {
        case .invalidPath, .symbolicLink: 403
        case .missingFile: 404
        case .unsupportedMediaType: 415
        case .resourceTooLarge: 413
        case .cancelled: 499
        }
    }

    nonisolated private static func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(
            NSError(domain: "OneReader.ReadOnlyContent", code: code)
        )
    }
}
