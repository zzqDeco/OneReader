#if os(iOS)
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import WebKit

struct NativeSelectableTextPresentation: UIViewRepresentable {
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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.alwaysBounceHorizontal = isCode
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 28, bottom: 36, right: 28)
        textView.textContainer.widthTracksTextView = !isCode
        textView.textContainer.lineBreakMode = isCode ? .byClipping : .byWordWrapping
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = isCode ? "代码阅读内容" : "文本阅读内容"
        apply(to: textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: UITextView, coordinator: Coordinator) {
        let signature = [
            kind.rawValue,
            AdapterUtilities.sha256(content),
            String(preferences.fontSize),
            String(preferences.lineSpacing),
            preferences.theme.rawValue,
        ].joined(separator: ":")
        if coordinator.renderSignature != signature {
            coordinator.renderSignature = signature
            let font = isCode
                ? UIFont.monospacedSystemFont(
                    ofSize: max(10, preferences.fontSize - 2),
                    weight: .regular
                )
                : UIFont.systemFont(ofSize: preferences.fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = preferences.lineSpacing
            paragraph.maximumLineHeight = font.pointSize + preferences.lineSpacing + 4
            if kind == .markdown {
                var renderer = NativeMarkdownRenderer(
                    fontSize: preferences.fontSize,
                    lineSpacing: preferences.lineSpacing
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

        init(parent: NativeSelectableTextPresentation) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingAnchor else { return }
            publishSelection(from: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingAnchor, let textView = scrollView as? UITextView else { return }
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
                guard let mapped = MarkdownSourceMap.sourceRange(
                    forRenderedRange: renderedRange,
                    in: textView.attributedText
                ) else { return }
                sourceRange = mapped
                payload["renderedStartUTF16"] = String(renderedRange.location)
            } else {
                sourceRange = renderedRange
            }
            guard NSMaxRange(sourceRange) <= sourceValue.length else { return }
            let exact = sourceValue.substring(with: sourceRange)
            guard !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let textBefore = sourceValue.substring(to: sourceRange.location)
            payload["startUTF16"] = String(sourceRange.location)
            payload["endUTF16"] = String(NSMaxRange(sourceRange))
            payload["startLine"] = String(
                textBefore.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            )
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
            let signature = AdapterUtilities.sha256("\(payload)|\(exact)|\(prefix)|\(suffix)")
            guard signature != lastPositionSignature else { return }
            lastPositionSignature = signature
            parent.onPositionChange(locator)
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

struct ManagedPDFPresentation: UIViewRepresentable {
    let url: URL
    let documentLocator: Locator
    let pageIndex: Int
    let scale: Double
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

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
            if let exact = documentLocator.textQuote?.exact,
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
                  let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let document = view.document else { return }
            let index = document.index(for: page)
            guard index >= 0 else { return }
            var payload = parent.documentLocator.payload
            payload["pageIndex"] = String(index)
            payload["rect"] = nil
            parent.onPositionChange(
                Locator(
                    sourceID: parent.documentLocator.sourceID,
                    snapshotID: parent.documentLocator.snapshotID,
                    adapterID: parent.documentLocator.adapterID,
                    payload: payload,
                    structuralPath: "page/\(index)",
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
    let preferences: ReaderPreferences
    let colorScheme: ColorScheme
    let onSelectionChange: (ReaderSelection?) -> Void
    let onPositionChange: (Locator) -> Void

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
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
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

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
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
            body { color: \(foreground); background: \(background); font: \(preferences.fontSize)px/\(1.45 + preferences.lineSpacing / 30) ui-serif, Georgia, serif; max-width: \(preferences.lineWidth)px; margin: 0 auto; padding: 28px 24px 72px; overflow-wrap: anywhere; }
            img, svg, video { max-width: 100%; height: auto; }
            pre { overflow-x: auto; }
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

    private static func javaScriptLiteral(_ value: String?) -> String {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "null" }
        return literal
    }

    private static func anchorScript(for locator: Locator) -> String {
        let selector = locator.payload["domPath"].flatMap { $0.isEmpty ? nil : $0 }
            ?? locator.structuralPath.flatMap { $0.hasPrefix("body") ? $0 : nil }
        return """
            (() => {
              const selector = \(javaScriptLiteral(selector));
              const quote = \(javaScriptLiteral(locator.textQuote?.exact));
              const selection = window.getSelection();
              if (!selector && !quote) {
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
                window.webkit.messageHandlers.oneReaderPosition.postMessage({ path: pathFor(element), quote: firstText(element) });
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

        init(parent: ControlledWebPresentation) { self.parent = parent }

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
                        textQuote: quote.flatMap {
                            $0.isEmpty ? nil : TextQuote(prefix: nil, exact: $0, suffix: nil)
                        },
                        fingerprint: quote.flatMap {
                            $0.isEmpty ? nil : AdapterUtilities.sha256($0)
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
#endif
