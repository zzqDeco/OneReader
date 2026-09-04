#if os(iOS)
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import WebKit

struct NativeSelectableTextPresentation: UIViewRepresentable {
    let content: String
    let contentIdentity: String
    let locator: Locator
    let kind: NativeTextPresentationKind
    let resourceRootURL: URL?
    let documentBaseURL: URL?
    let captureTargetID: UUID
    let preferences: ReaderPreferences
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (ReadingPositionUpdate) -> Void

    private var isCode: Bool { kind == .code }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ReaderTextViewportView {
        let viewport = ReaderTextViewportView()
        let textView = viewport.textView
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = isCode
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(
            top: 26,
            left: ReaderTheme.compactInset,
            bottom: 42,
            right: ReaderTheme.compactInset
        )
        textView.textContainer.widthTracksTextView = !isCode
        textView.textContainer.heightTracksTextView = false
        textView.textContainer.lineBreakMode = isCode ? .byClipping : .byWordWrapping
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = isCode ? "代码阅读内容" : "文本阅读内容"
        context.coordinator.observeCaptureRequests(for: textView)
        apply(to: textView, coordinator: context.coordinator)
        return viewport
    }

    func updateUIView(_ viewport: ReaderTextViewportView, context: Context) {
        context.coordinator.parent = self
        apply(to: viewport.textView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ReaderTextViewportView,
        context: Context
    ) -> CGSize? {
        ReaderViewportSizing.finiteSize(
            width: proposal.width,
            height: proposal.height
        )
    }

    static func dismantleUIView(_ viewport: ReaderTextViewportView, coordinator: Coordinator) {
        coordinator.publishPositionImmediately(from: viewport.textView)
        coordinator.stopObservingCaptureRequests()
    }

    private func apply(to textView: UITextView, coordinator: Coordinator) {
        let measuredWidth = textView.bounds.width
            - textView.textContainerInset.left
            - textView.textContainerInset.right
        let fallbackWidth = (textView.window?.windowScene?.screen.bounds.width ?? 430) - 44
        let maximumImageWidth = min(
            ReaderTheme.proseMaxWidth,
            max(220, measuredWidth > 0 ? measuredWidth : fallbackWidth)
        )
        let signature = [
            kind.rawValue,
            contentIdentity,
            String(preferences.fontSize),
            String(preferences.lineSpacing),
            preferences.theme.rawValue,
            resourceRootURL?.standardizedFileURL.path ?? "",
            documentBaseURL?.standardizedFileURL.path ?? "",
            String(Int(maximumImageWidth.rounded())),
        ].joined(separator: ":")
        if coordinator.renderSignature != signature {
            coordinator.renderSignature = signature
            let baseFont = isCode
                ? UIFont.monospacedSystemFont(
                    ofSize: max(10, preferences.fontSize - 2),
                    weight: .regular
                )
                : readerSerifFont(ofSize: preferences.fontSize)
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = preferences.lineSpacing
            paragraph.maximumLineHeight = font.pointSize + preferences.lineSpacing + 4
            if kind == .markdown {
                var renderer = NativeMarkdownRenderer(
                    fontSize: font.pointSize,
                    lineSpacing: preferences.lineSpacing,
                    resourceRootURL: resourceRootURL,
                    documentBaseURL: documentBaseURL,
                    maximumImageWidth: maximumImageWidth
                )
                textView.attributedText = renderer.render(content)
            } else {
                textView.attributedText = NSAttributedString(
                    string: content,
                    attributes: [
                        .font: font,
                        .paragraphStyle: paragraph,
                        .foregroundColor: UIColor.label,
                    ]
                )
            }
            coordinator.anchorSignature = nil
        }
        applyAnchor(to: textView, coordinator: coordinator)
    }

    private func readerSerifFont(ofSize size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func applyAnchor(to textView: UITextView, coordinator: Coordinator) {
        let signature = [
            locator.stableID,
            locator.textQuote?.prefix ?? "",
            locator.textQuote?.exact ?? "",
            locator.textQuote?.suffix ?? "",
            locator.fingerprint ?? "",
        ].joined(separator: ":")
        guard coordinator.anchorSignature != signature else { return }
        coordinator.anchorSignature = signature
        let value = textView.attributedText.string as NSString
        let targetRange: NSRange
        if kind == .markdown,
           let start = locator.payload["startUTF16"].flatMap(Int.init),
           let end = locator.payload["endUTF16"].flatMap(Int.init),
           let mapped = MarkdownSourceMap.renderedRange(
               forSourceRange: NSRange(location: start, length: max(0, end - start)),
               in: textView.attributedText
           ) {
            targetRange = mapped
        } else if let quote = locator.textQuote,
                  let match = Self.range(of: quote, in: value) {
            targetRange = match
        } else if let rawStart = locator.payload[
            kind == .markdown ? "renderedStartUTF16" : "startUTF16"
        ], let start = Int(rawStart), start >= 0, start <= value.length {
            let end = kind == .markdown
                ? start
                : min(max(start, Int(locator.payload["endUTF16"] ?? "") ?? start), value.length)
            targetRange = NSRange(location: start, length: end - start)
        } else {
            targetRange = NSRange(location: 0, length: 0)
        }
        coordinator.isApplyingAnchor = true
        textView.selectedRange = targetRange
        if targetRange.location > 0 || targetRange.length > 0 {
            textView.scrollRangeToVisible(targetRange)
        }
        DispatchQueue.main.async {
            coordinator.isApplyingAnchor = false
        }
    }

    private static func range(of quote: TextQuote, in value: NSString) -> NSRange? {
        guard !quote.exact.isEmpty else { return nil }
        var searchRange = NSRange(location: 0, length: value.length)
        while searchRange.length > 0 {
            let match = value.range(of: quote.exact, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            let prefixMatches = quote.prefix.map { prefix in
                let length = min((prefix as NSString).length, match.location)
                return value.substring(
                    with: NSRange(location: match.location - length, length: length)
                ).hasSuffix(prefix)
            } ?? true
            let suffixMatches = quote.suffix.map { suffix in
                let start = NSMaxRange(match)
                let length = min((suffix as NSString).length, value.length - start)
                return value.substring(with: NSRange(location: start, length: length))
                    .hasPrefix(suffix)
            } ?? true
            if prefixMatches && suffixMatches { return match }
            let next = NSMaxRange(match)
            guard next < value.length else { break }
            searchRange = NSRange(location: next, length: value.length - next)
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeSelectableTextPresentation
        var renderSignature: String?
        var anchorSignature: String?
        var isApplyingAnchor = false
        private var lastPositionSignature: String?
        private var positionPublishTask: Task<Void, Never>?
        private var lastPositionChange = Date.distantPast
        private weak var observedTextView: UITextView?

        deinit {
            positionPublishTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        init(parent: NativeSelectableTextPresentation) {
            self.parent = parent
        }

        func observeCaptureRequests(for textView: UITextView) {
            observedTextView = textView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(positionCaptureRequested(_:)),
                name: ReadingPositionCaptureSignal.requested,
                object: nil
            )
        }

        func stopObservingCaptureRequests() {
            positionPublishTask?.cancel()
            positionPublishTask = nil
            observedTextView = nil
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func positionCaptureRequested(_ notification: Notification) {
            guard let textView = observedTextView, !isApplyingAnchor else { return }
            if let request = notification.object as? ReadingPositionCaptureRequest {
                let targetID = parent.captureTargetID
                guard request.claim(targetID: targetID, locator: parent.locator) else {
                    return
                }
                publishPositionImmediately(from: textView)
                request.finish(with: nil, targetID: targetID)
                return
            }
            publishPositionImmediately(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingAnchor else { return }
            publishSelection(from: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingAnchor, let textView = scrollView as? UITextView else { return }
            schedulePositionPublish(from: textView)
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            guard !decelerate, let textView = scrollView as? UITextView else { return }
            publishPositionImmediately(from: textView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            publishPositionImmediately(from: textView)
        }

        private func schedulePositionPublish(from textView: UITextView) {
            lastPositionChange = .now
            guard positionPublishTask == nil else { return }
            positionPublishTask = Task { @MainActor [weak self, weak textView] in
                while let self, !Task.isCancelled {
                    let elapsed = Date.now.timeIntervalSince(lastPositionChange)
                    if elapsed < 0.15 {
                        let remaining = max(1, Int(ceil((0.15 - elapsed) * 1_000)))
                        do {
                            try await Task.sleep(for: .milliseconds(remaining))
                        } catch {
                            return
                        }
                        continue
                    }
                    guard let textView, !isApplyingAnchor else {
                        positionPublishTask = nil
                        return
                    }
                    positionPublishTask = nil
                    publishPosition(from: textView)
                    return
                }
            }
        }

        func publishPositionImmediately(from textView: UITextView) {
            positionPublishTask?.cancel()
            positionPublishTask = nil
            guard !isApplyingAnchor else { return }
            publishPosition(from: textView)
        }

        private func publishSelection(from textView: UITextView) {
            let range = textView.selectedRange
            let renderedValue = textView.attributedText.string as NSString
            guard range.length > 0, NSMaxRange(range) <= renderedValue.length else {
                parent.onSelectionChange(nil)
                return
            }
            var payload = parent.locator.payload
            ["startUTF16", "endUTF16", "startLine", "endLine", "renderedStartUTF16"]
                .forEach { payload[$0] = nil }
            let sourceRange: NSRange
            if parent.kind == .markdown {
                guard let mapped = MarkdownSourceMap.sourceRange(
                    forRenderedRange: range,
                    in: textView.attributedText
                ) else {
                    parent.onSelectionChange(nil)
                    return
                }
                sourceRange = mapped
                payload["renderedStartUTF16"] = String(range.location)
            } else {
                sourceRange = range
            }
            let sourceValue = parent.content as NSString
            guard sourceRange.location != NSNotFound,
                  NSMaxRange(sourceRange) <= sourceValue.length else {
                parent.onSelectionChange(nil)
                return
            }
            let exact = sourceValue.substring(with: sourceRange)
            let textBefore = sourceValue.substring(to: sourceRange.location)
            let startLine = textBefore.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lineCount = exact.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            payload["startUTF16"] = String(sourceRange.location)
            payload["endUTF16"] = String(NSMaxRange(sourceRange))
            payload["startLine"] = String(startLine)
            payload["endLine"] = String(startLine + lineCount)
            let prefix = context(
                in: sourceValue,
                start: max(0, sourceRange.location - 48),
                length: min(48, sourceRange.location)
            )
            let suffixStart = NSMaxRange(sourceRange)
            let suffix = context(
                in: sourceValue,
                start: suffixStart,
                length: min(48, sourceValue.length - suffixStart)
            )
            let locator = Locator(
                sourceID: parent.locator.sourceID,
                snapshotID: parent.locator.snapshotID,
                adapterID: parent.locator.adapterID,
                payload: payload,
                structuralPath: parent.locator.structuralPath,
                textQuote: TextQuote(
                    prefix: prefix.isEmpty ? nil : prefix,
                    exact: exact,
                    suffix: suffix.isEmpty ? nil : suffix
                ),
                fingerprint: AdapterUtilities.sha256(exact)
            )
            parent.onSelectionChange(
                ReaderSelection(text: renderedValue.substring(with: range), locator: locator)
            )
        }

        private func publishPosition(from textView: UITextView) {
            let renderedValue = textView.attributedText.string as NSString
            guard renderedValue.length > 0 else { return }
            let point = CGPoint(
                x: textView.textContainerInset.left + 2,
                y: textView.contentOffset.y + textView.textContainerInset.top + 2
            )
            let glyph = textView.layoutManager.glyphIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            let start = min(
                max(0, textView.layoutManager.characterIndexForGlyph(at: glyph)),
                renderedValue.length
            )
            let raw = NSRange(location: start, length: min(96, renderedValue.length - start))
            let renderedRange = renderedValue.rangeOfComposedCharacterSequences(for: raw)
            guard renderedRange.length > 0 else { return }
            var payload = parent.locator.payload
            let sourceValue = parent.content as NSString
            let sourceRange: NSRange
            if parent.kind == .markdown {
                guard let anchor = MarkdownSourceMap.positionAnchor(
                    forRenderedRange: renderedRange,
                    in: textView.attributedText
                ) else { return }
                sourceRange = anchor.sourceRange
                payload["renderedStartUTF16"] = String(anchor.renderedLocation)
            } else {
                sourceRange = renderedRange
            }
            guard NSMaxRange(sourceRange) <= sourceValue.length else { return }
            let exact = sourceValue.substring(with: sourceRange)
            guard !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let textBefore = sourceValue.substring(to: sourceRange.location)
            payload["startUTF16"] = String(sourceRange.location)
            payload["endUTF16"] = String(NSMaxRange(sourceRange))
            let startLine = textBefore.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let endLine = exact.reduce(startLine) { $1 == "\n" ? $0 + 1 : $0 }
            payload["startLine"] = String(startLine)
            payload["endLine"] = String(endLine)
            let prefix = context(
                in: sourceValue,
                start: max(0, sourceRange.location - 48),
                length: min(48, sourceRange.location)
            )
            let suffixStart = NSMaxRange(sourceRange)
            let suffix = context(
                in: sourceValue,
                start: suffixStart,
                length: min(48, sourceValue.length - suffixStart)
            )
            let locator = Locator(
                sourceID: parent.locator.sourceID,
                snapshotID: parent.locator.snapshotID,
                adapterID: parent.locator.adapterID,
                payload: payload,
                structuralPath: parent.locator.relativePath
                    ?? parent.locator.structuralPath,
                textQuote: TextQuote(
                    prefix: prefix.isEmpty ? nil : prefix,
                    exact: exact,
                    suffix: suffix.isEmpty ? nil : suffix
                ),
                fingerprint: AdapterUtilities.sha256(exact)
            )
            let signature = AdapterUtilities.sha256("\(payload)|\(exact)|\(prefix)|\(suffix)")
            guard signature != lastPositionSignature else { return }
            lastPositionSignature = signature
            let sourceLength = max(1, sourceValue.length)
            let fraction = Double(sourceRange.location) / Double(sourceLength)
            let line = Int(payload["startLine"] ?? "") ?? 1
            parent.onPositionChange(
                ReadingPositionUpdate(
                    locator: locator,
                    progressFraction: fraction,
                    granularity: .text,
                    displayLabel: ReadingPositionUpdate.label(
                        for: locator,
                        detail: "第 \(line) 行 · \(Int(fraction * 100))%"
                    )
                )
            )
        }

        private func context(in value: NSString, start: Int, length: Int) -> String {
            guard length > 0 else { return "" }
            let range = value.rangeOfComposedCharacterSequences(
                for: NSRange(location: start, length: length)
            )
            return value.substring(with: range)
        }
    }
}

final class ReaderTextViewportView: UIView {
    let textView = UITextView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: UIView.noIntrinsicMetric
        )
    }
}

struct ManagedPDFPresentation: UIViewRepresentable {
    let url: URL
    let documentLocator: Locator
    let pageIndex: Int
    let scale: Double
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (ReadingPositionUpdate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.loadedURL = url
            context.coordinator.appliedAnchorSignature = nil
        }
        view.scaleFactor = min(max(scale, 0.5), 3)
        let signature = [
            documentLocator.stableID,
            documentLocator.textQuote?.exact ?? "",
            documentLocator.payload["rect"] ?? "",
        ].joined(separator: ":")
        if context.coordinator.appliedAnchorSignature != signature,
           let page = view.document?.page(at: pageIndex) {
            context.coordinator.isApplyingAnchor = true
            context.coordinator.appliedAnchorSignature = signature
            if let anchor = PDFPageRectAnchor.parse(documentLocator.payload["rect"]),
               let rect = anchor.clipped(to: page.bounds(for: .mediaBox)) {
                if let selection = page.selection(for: rect) {
                    if let exact = documentLocator.textQuote?.exact {
                        if selection.string?.contains(exact) == true {
                            view.setCurrentSelection(selection, animate: false)
                        }
                    } else {
                        view.setCurrentSelection(selection, animate: false)
                    }
                }
                view.go(to: rect, on: page)
            } else if let exact = documentLocator.textQuote?.exact,
               let pageText = page.string,
               let range = pageText.range(of: exact),
               let selection = page.selection(for: NSRange(range, in: pageText)) {
                view.setCurrentSelection(selection, animate: false)
                view.go(to: selection)
            } else {
                view.go(to: page)
            }
            DispatchQueue.main.async {
                context.coordinator.isApplyingAnchor = false
                context.coordinator.publishPosition(from: view)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ManagedPDFPresentation
        var loadedURL: URL?
        var appliedAnchorSignature: String?
        var isApplyingAnchor = false

        init(parent: ManagedPDFPresentation) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: .PDFViewSelectionChanged,
                object: view
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
                  let view = notification.object as? PDFView else { return }
            publishPosition(from: view)
        }

        func publishPosition(from view: PDFView) {
            guard !isApplyingAnchor,
                  let page = view.currentPage,
                  let document = view.document else { return }
            let index = document.index(for: page)
            guard index >= 0 else { return }
            var payload = parent.documentLocator.payload
            payload["pageIndex"] = String(index)
            payload["rect"] = nil
            let locator = Locator(
                sourceID: parent.documentLocator.sourceID,
                snapshotID: parent.documentLocator.snapshotID,
                adapterID: parent.documentLocator.adapterID,
                payload: payload,
                structuralPath: "page/\(index)",
                textQuote: nil,
                fingerprint: nil
            )
            let pageCount = document.pageCount
            let fraction = pageCount > 0
                ? Double(index + 1) / Double(pageCount)
                : nil
            let detail = pageCount > 0
                ? "第 \(index + 1) / \(pageCount) 页"
                : "第 \(index + 1) 页"
            parent.onPositionChange(
                ReadingPositionUpdate(
                    locator: locator,
                    progressFraction: fraction,
                    granularity: .page,
                    displayLabel: ReadingPositionUpdate.label(
                        for: locator,
                        detail: detail
                    )
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
            let index = document.index(for: page)
            let rect = selection.bounds(for: page)
            var payload = parent.documentLocator.payload
            payload["pageIndex"] = String(index)
            payload["rect"] = [rect.minX, rect.minY, rect.width, rect.height]
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            let locator = Locator(
                sourceID: parent.documentLocator.sourceID,
                snapshotID: parent.documentLocator.snapshotID,
                adapterID: parent.documentLocator.adapterID,
                payload: payload,
                structuralPath: "page/\(index)",
                textQuote: TextQuote(prefix: nil, exact: selected, suffix: nil),
                fingerprint: AdapterUtilities.sha256(selected)
            )
            parent.onSelectionChange(ReaderSelection(text: selected, locator: locator))
        }
    }
}

struct ManagedQuickLookPresentation: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

struct ControlledWebPresentation: UIViewRepresentable {
    let document: PresentationDocument
    let captureTargetID: UUID
    let preferences: ReaderPreferences
    let colorScheme: ColorScheme
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (ReadingPositionUpdate) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
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
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        context.coordinator.observeCaptureRequests(for: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let renderID = [
            document.id,
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
        context.coordinator.resetCapturedPosition()
        let baseURL = URL(string: "onereader-content://\(document.locator.snapshotID)/")
        view.loadHTMLString(styledHTML, baseURL: baseURL)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stopObservingCaptureRequests()
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.selectionHandlerName
        )
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.positionHandlerName
        )
    }

    private var styledHTML: String {
        let isDark = colorScheme == .dark
        let foreground = isDark ? "#E8E6E1" : "#22211E"
        let secondary = isDark ? "#AAA7A0" : "#66625B"
        let border = isDark ? "#3A3B3C" : "#D8D2C7"
        let muted = isDark ? "#202224" : "#F1EEE6"
        let background = isDark ? "#161719" : "#FBFAF6"
        let style = """
            <style id="onereader-reader-theme">
            :root { color-scheme: \(isDark ? "dark" : "light"); }
            * { box-sizing: border-box; }
            body { color: \(foreground); background: \(background); font: \(preferences.fontSize)px/\(1.52 + preferences.lineSpacing / 32) ui-serif, Georgia, serif; max-width: \(min(preferences.lineWidth, ReaderTheme.proseMaxWidth))px; margin: 0 auto; padding: 28px 22px 80px; overflow-wrap: anywhere; }
            h1, h2, h3 { line-height: 1.22; letter-spacing: -0.015em; margin: 1.45em 0 .55em; }
            h1:first-child, h2:first-child { margin-top: 0; }
            p, ul, ol { margin: 0 0 1em; }
            img, svg, video { display: block; max-width: 100%; height: auto; margin: 1.4em auto; border-radius: 8px; }
            pre { overflow-x: auto; padding: 14px; border: 1px solid \(border); border-radius: 8px; background: \(muted); }
            pre, code { font-family: ui-monospace, SFMono-Regular, monospace; }
            code { font-size: .9em; }
            blockquote { color: \(secondary); margin: 1.25em 0; padding: .1em 0 .1em 1em; border-left: 3px solid #0F766E; }
            table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 1.3em 0; font-size: .92em; }
            th, td { padding: .62em .72em; border-bottom: 1px solid \(border); text-align: left; white-space: nowrap; }
            th { background: \(muted); font-weight: 600; }
            hr { border: 0; border-top: 1px solid \(border); margin: 1.8em 0; }
            a { color: #0F766E; text-underline-offset: .16em; }
            ::selection { background: rgba(177, 125, 56, .30); }
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

    private static func javaScriptLiteral(_ value: String?) -> String {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "null" }
        return literal
    }

    static func anchorScript(for locator: Locator) -> String {
        let selector = locator.payload["domPath"].flatMap { $0.isEmpty ? nil : $0 }
            ?? locator.structuralPath.flatMap { $0.hasPrefix("body") ? $0 : nil }
        let scrollFraction = locator.payload["scrollFraction"]
        return """
            (() => {
              const selector = \(javaScriptLiteral(selector));
              const quote = \(javaScriptLiteral(locator.textQuote?.exact));
              const rawFraction = \(javaScriptLiteral(scrollFraction));
              const fraction = rawFraction === null ? null : Number(rawFraction);
              const selection = window.getSelection();
              function restoreFraction() {
                if (!Number.isFinite(fraction)) return false;
                const root = document.scrollingElement || document.documentElement;
                const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
                window.__oneReaderApplyingAnchor = true;
                if (selection) selection.removeAllRanges();
                window.scrollTo({ top: Math.min(1, Math.max(0, fraction)) * maximum, behavior: 'auto' });
                requestAnimationFrame(() => { window.__oneReaderApplyingAnchor = false; });
                return true;
              }
              if (!selector && !quote) {
                if (restoreFraction()) return true;
                window.__oneReaderApplyingAnchor = true;
                if (selection) selection.removeAllRanges();
                window.scrollTo({ top: 0, behavior: 'auto' });
                requestAnimationFrame(() => { window.__oneReaderApplyingAnchor = false; });
                return true;
              }
              let target = null;
              if (selector) { try { target = document.querySelector(selector); } catch (_) {} }
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
              if (textNode) target = textNode.parentElement;
              if (!target) return restoreFraction();
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
              if (Number.isFinite(fraction)) {
                const root = document.scrollingElement || document.documentElement;
                const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
                window.scrollTo({ top: Math.min(1, Math.max(0, fraction)) * maximum, behavior: 'auto' });
              } else {
                target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
              }
              requestAnimationFrame(() => { window.__oneReaderApplyingAnchor = false; });
              return true;
            })();
            """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let selectionHandlerName = "oneReaderSelection"
        static let positionHandlerName = "oneReaderPosition"
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
                return parts.length ? 'body > ' + parts.join(' > ') : 'body';
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
                return parts.length ? 'body > ' + parts.join(' > ') : 'body';
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
              function capturePosition() {
                const referenceY = Math.min(96, Math.max(1, window.innerHeight / 4));
                const element = document.elementFromPoint(Math.max(1, window.innerWidth / 2), referenceY) || document.body;
                let anchor = null;
                for (const heading of document.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
                  if (heading.getBoundingClientRect().top <= referenceY) anchor = heading;
                  else break;
                }
                const root = document.scrollingElement || document.documentElement;
                const maximum = Math.max(0, root.scrollHeight - window.innerHeight);
                const fraction = maximum > 0 ? root.scrollTop / maximum : 1;
                return {
                  path: pathFor(element),
                  outlinePath: anchor ? pathFor(anchor) : '',
                  quote: firstText(element),
                  fraction
                };
              }
              window.__oneReaderCapturePosition = capturePosition;
              function publish() {
                if (window.__oneReaderApplyingAnchor) return;
                window.webkit.messageHandlers.oneReaderPosition.postMessage(capturePosition());
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
        private weak var observedWebView: WKWebView?
        private var lastPath: String?
        private var lastOutlinePath: String?
        private var lastQuote: String?
        private var lastFraction: Double?

        init(parent: ControlledWebPresentation) { self.parent = parent }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observeCaptureRequests(for webView: WKWebView) {
            observedWebView = webView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(positionCaptureRequested(_:)),
                name: ReadingPositionCaptureSignal.requested,
                object: nil
            )
        }

        func stopObservingCaptureRequests() {
            observedWebView = nil
            NotificationCenter.default.removeObserver(
                self,
                name: ReadingPositionCaptureSignal.requested,
                object: nil
            )
        }

        func resetCapturedPosition() {
            lastPath = nil
            lastOutlinePath = nil
            lastQuote = nil
            lastFraction = nil
        }

        @objc private func positionCaptureRequested(_ notification: Notification) {
            guard let observedWebView else { return }
            if let request = notification.object as? ReadingPositionCaptureRequest {
                let targetID = parent.captureTargetID
                guard request.claim(
                    targetID: targetID,
                    locator: parent.document.locator
                ) else { return }
                captureCurrentPosition(from: observedWebView) { update in
                    request.finish(with: update, targetID: targetID)
                }
                return
            }
            publishPositionImmediately(from: observedWebView)
        }

        func publishPositionImmediately(from webView: WKWebView) {
            captureCurrentPosition(from: webView) { [weak self] update in
                self?.parent.onPositionChange(update)
            }
        }

        private func captureCurrentPosition(
            from webView: WKWebView,
            completion: @escaping @MainActor (ReadingPositionUpdate) -> Void
        ) {
            let base = parent.document.locator
            let fallbackFraction = lastFraction
            guard !webView.isLoading else {
                completion(
                    WebReadingPositionCapture.fractionOnlyUpdate(
                        for: base,
                        fraction: fallbackFraction
                    )
                )
                return
            }
            Task { @MainActor [weak self, weak webView] in
                guard let webView else {
                    completion(
                        WebReadingPositionCapture.fractionOnlyUpdate(
                            for: base,
                            fraction: fallbackFraction
                        )
                    )
                    return
                }
                let result = try? await webView.evaluateJavaScript(
                    WebReadingPositionCapture.currentPositionJavaScript
                )
                guard let body = result as? [String: Any],
                      let number = body["fraction"] as? NSNumber,
                      number.doubleValue.isFinite else {
                    completion(
                        WebReadingPositionCapture.fractionOnlyUpdate(
                            for: base,
                            fraction: fallbackFraction
                        )
                    )
                    return
                }
                let path = (body["path"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let outlinePath = (body["outlinePath"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = (body["quote"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fraction = min(max(number.doubleValue, 0), 1)
                if let path, !path.isEmpty { self?.lastPath = path }
                if let outlinePath, !outlinePath.isEmpty {
                    self?.lastOutlinePath = outlinePath
                }
                if let quote, !quote.isEmpty { self?.lastQuote = quote }
                self?.lastFraction = fraction
                completion(
                    WebReadingPositionCapture.capturedUpdate(
                        for: base,
                        path: path,
                        outlinePath: outlinePath,
                        quote: quote,
                        fraction: fraction
                    )
                )
            }
        }

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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let anchorID = pendingAnchorID
                ?? ControlledWebPresentation.anchorSignature(parent.document.locator)
            applyAnchor(anchorID, in: webView)
        }

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
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let allowed = navigationAction.navigationType == .other
                && (url.scheme == "about" || url.scheme == "onereader-content")
            decisionHandler(allowed ? .allow : .cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            if message.name == Self.positionHandlerName {
                let path = body["path"] as? String
                let outlinePath = body["outlinePath"] as? String
                let quote = (body["quote"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fraction = (body["fraction"] as? NSNumber)?.doubleValue
                if let path, !path.isEmpty { lastPath = path }
                if let outlinePath, !outlinePath.isEmpty {
                    lastOutlinePath = outlinePath
                }
                if let quote, !quote.isEmpty { lastQuote = quote }
                if let fraction, fraction.isFinite {
                    lastFraction = min(max(fraction, 0), 1)
                }
                parent.onPositionChange(
                    WebReadingPositionCapture.update(
                        for: parent.document.locator,
                        path: lastPath,
                        outlinePath: lastOutlinePath,
                        quote: lastQuote,
                        fraction: lastFraction
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
#endif
