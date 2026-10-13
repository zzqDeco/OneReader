import PDFKit
#if os(macOS)
import AppKit
typealias OCRPlatformView = NSView
typealias OCRPlatformButton = NSButton
#else
import UIKit
typealias OCRPlatformView = UIView
typealias OCRPlatformButton = UIButton
#endif

/// Overlay views are owned by PDFKit and follow its native page transforms. They do not render
/// replacement pages or add text to the original PDF. Only explicit OCR-selection mode hit-tests.
@MainActor
final class OCRPDFOverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private var signature = ""
    private var revision: OCRRevision?
    private var selectable = false
    private var selectedSpanID: String?
    private var selectedRect: CGRect?
    private var selectedPageIndex: Int?
    private var selectedText = ""
    private var onSelection: ((ReaderSelection?) -> Void)?

    func install(in view: PDFView, revision: OCRRevision?, selectable: Bool, locator: Locator,
                 onSelection: @escaping (ReaderSelection?) -> Void) {
        self.onSelection = onSelection
        let next = "\(revision?.id ?? ""):\(selectable):\(locator.stableID)"
        guard next != signature else { return }
        signature = next; self.revision = revision; self.selectable = selectable
        selectedSpanID = locator.payload["ocrSpanID"]
        selectedRect = PDFPageRectAnchor.parse(locator.payload["rect"])?.rect
        selectedPageIndex = locator.pdfPageIndex
        selectedText = locator.textQuote?.exact ?? "识别文字"
        view.pageOverlayViewProvider = nil
        view.pageOverlayViewProvider = revision == nil ? nil : self
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> OCRPlatformView? {
        guard let document = view.document, let revision,
              let result = revision.pages.first(where: { $0.pageIndex == document.index(for: page) }),
              !result.usesNativeText else { return nil }
        let overlay = OCRPageOverlayView()
        overlay.pdfView = view; overlay.page = page
        let spans = selectable ? result.spans : result.spans.filter { $0.id == selectedSpanID }
        overlay.entries = spans.map { span in
            let anchor = revision.locator(page: result, span: span)
            return (span.bounds.rect, span.text, span.id == selectedSpanID, { [weak self] in
                self?.onSelection?(ReaderSelection(text: span.text, locator: anchor))
            })
        }
        if !selectable, selectedSpanID == nil, selectedPageIndex == result.pageIndex, let selectedRect {
            overlay.entries.append((selectedRect, selectedText, true, {}))
        }
        overlay.selectable = selectable
        overlay.build()
        return overlay
    }
}

@MainActor
private final class OCRPageOverlayView: OCRPlatformView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var selectable = false
    var entries: [(CGRect, String, Bool, () -> Void)] = []
    private var controls: [OCRSpanButton] = []

    func build() {
        for entry in entries {
            let button = OCRSpanButton()
            button.actionClosure = entry.3
#if os(macOS)
            button.title = ""; button.isBordered = false
            button.target = button; button.action = #selector(OCRSpanButton.selectSpan)
            button.setAccessibilityLabel("识别文字：\(entry.1)")
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(entry.2 ? 0.28 : 0.06).cgColor
            button.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
            button.layer?.borderWidth = selectable ? 0.5 : 0
#else
            button.accessibilityLabel = "识别文字：\(entry.1)"
            button.addTarget(button, action: #selector(OCRSpanButton.selectSpan), for: .touchUpInside)
            button.backgroundColor = UIColor.systemYellow.withAlphaComponent(entry.2 ? 0.28 : 0.06)
            button.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
            button.layer.borderWidth = selectable ? 0.5 : 0
#endif
            addSubview(button); controls.append(button)
        }
    }

#if os(macOS)
    override func layout() { super.layout(); positionSpans() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard selectable else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
#else
    override func layoutSubviews() { super.layoutSubviews(); positionSpans() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard selectable else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
#endif
    private func positionSpans() {
        guard let pdfView, let page else { return }
        for (index, entry) in entries.enumerated() {
            controls[index].frame = convert(pdfView.convert(entry.0, from: page), from: pdfView)
        }
    }
}

@MainActor
private final class OCRSpanButton: OCRPlatformButton {
    var actionClosure: (() -> Void)?
    @objc func selectSpan() { actionClosure?() }
}
