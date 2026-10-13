import Foundation

/// PDFKit owns its native text layer. A displayed OCR page does not change the
/// identity of text selected later on another (native) page in the same view.
enum NativePDFSelectionAnchor {
    static func selection(base: Locator, pageIndex: Int, rectangle: CGRect, text: String) -> ReaderSelection? {
        guard pageIndex >= 0, !text.isEmpty, !rectangle.isNull, !rectangle.isEmpty,
              [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].allSatisfy(\.isFinite) else { return nil }
        var payload = base.payload
        let removed = PDFViewportAnchor.payloadKeys + ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText",
            "startUTF16", "endUTF16", "indexTextRange", "pageTextStartUTF16", "pageTextEndUTF16"]
        removed.forEach { payload[$0] = nil }
        payload["pageIndex"] = String(pageIndex)
        payload["rect"] = [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
        let locator = Locator(sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: PDFAdapter.id,
            payload: payload, structuralPath: "page/\(pageIndex)",
            textQuote: TextQuote(prefix: nil, exact: text, suffix: nil), fingerprint: AdapterUtilities.sha256(text))
        return ReaderSelection(text: text, locator: locator)
    }
}
