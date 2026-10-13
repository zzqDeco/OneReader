import Foundation
import PDFKit

struct OCRAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter, IndexingAdapter {
    static let id = "onereader.ocr"
    let database: LibraryDatabase
    let descriptor = AdapterDescriptor(id: id, version: "1.0.0", displayName: "本机识别文字",
        probeRule: AdapterProbeRule(filenameExtensions: ["pdf", "jpeg", "jpg", "png", "heic"], mediaTypes: [], sourceOrigins: [.localFile, .remoteURL], magicPrefixes: []),
        capabilities: Set(AdapterCapability.allCases), limitations: ["识别文字可能有误，引用应对照原图核实。"])

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard let revision = try database.activeOCRRevision(snapshotID: context.snapshot.id),
              revision.sourceID == context.source.id else { return nil }
        return AdapterProbeMatch(adapterID: Self.id, confidence: 1,
            evidence: [ProbeEvidence(id: "ocr:\(revision.id)", adapterID: Self.id,
                rule: "ocr-revision", detail: revision.id, confidence: 1)],
            reason: "本机识别已覆盖 \(revision.pages.filter { !$0.usesNativeText }.count) 页；未识别页保留原文",
            auxiliaryAdapterIDs: [context.filenameExtension == "pdf" ? PDFAdapter.id : ImageAdapter.id])
    }

    func verifyRevision(in context: AdapterContext) async throws {
        if context.filenameExtension == "pdf" { try await PDFAdapter().verifyRevision(in: context) }
        else { try await ImageAdapter().verifyRevision(in: context) }
    }

    func listContent(in context: AdapterContext, under locator: Locator?, limit: Int) async throws -> [ContentNode] {
        let revision = try revision(context, locator: locator)
        let count = try VisionOCREngine.pageCount(context: context)
        return (0..<min(count, max(1, limit))).map { index in
            let page = revision.pages.first { $0.pageIndex == index && !$0.usesNativeText }
            let anchor = page.map { revision.locator(page: $0) } ?? nativeLocator(context, pageIndex: index)
            return ContentNode(id: anchor.stableID, title: "第 \(index + 1) 页\(page == nil ? "" : " · 识别文字")",
                kind: .page, locator: anchor, depth: 0, order: index,
                mediaType: context.filenameExtension == "pdf" ? "application/pdf" : "image/\(context.filenameExtension)", isReadable: true)
        }
    }

    func readFragment(in context: AdapterContext, at locator: Locator, maxCharacters: Int) async throws -> Observation {
        try context.validate(locator, adapterID: Self.id)
        guard locator.payload["ocrSchema"] == "1", locator.payload["ocrRevisionID"] != nil else {
            throw OCRError.missingRevision
        }
        let revision = try revision(context, locator: locator)
        let pageIndex = locator.pdfPageIndex ?? 0
        guard let page = revision.pages.first(where: { $0.pageIndex == pageIndex }), !page.usesNativeText else {
            throw OCRError.missingRevision
        }
        let text: String
        if let spanID = locator.payload["ocrSpanID"] {
            guard let span = page.spans.first(where: { $0.id == spanID }),
                  locator.payload["rect"] == span.bounds.locatorValue else { throw OCRError.missingRevision }
            text = try validatedText(span.text, locator: locator)
        } else {
            if locator.payload["startUTF16"] == nil, locator.payload["rect"] != nil { throw OCRError.missingRevision }
            text = try validatedText(page.text, locator: locator)
            _ = try enrichedLocator(locator, page: page)
        }
        return AdapterUtilities.makeObservation(context: context, adapterID: Self.id, locator: locator,
            mediaType: "text/plain; derived=ocr; engine=apple-vision", content: text,
            maxCharacters: maxCharacters, contentReference: "ocr:\(revision.id)/\(pageIndex)")
    }

    func searchContent(in context: AdapterContext, query: String, limit: Int) async throws -> [ContentSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let revision = try revision(context, locator: nil)
        var hits: [ContentSearchHit] = []
        for page in revision.pages where !page.usesNativeText {
            for span in page.spans where span.text.localizedCaseInsensitiveContains(query) {
                let anchor = revision.locator(page: page, span: span)
                hits.append(ContentSearchHit(id: anchor.stableID, sourceID: context.source.id,
                    snapshotID: context.snapshot.id, adapterID: Self.id, locator: anchor,
                    title: "第 \(page.pageIndex + 1) 页 · 识别文字", context: span.text, rank: 1))
                if hits.count >= limit { return hits }
            }
        }
        if context.filenameExtension == "pdf" {
            let excluded = Set(revision.pages.filter { !$0.usesNativeText }.map(\.pageIndex))
            let native = try await PDFAdapter().searchContent(in: context, query: query, limit: 20)
            hits.append(contentsOf: native.filter { !excluded.contains($0.locator.pdfPageIndex ?? 0) }.prefix(limit - hits.count))
        }
        return hits
    }

    func indexContent(in context: AdapterContext, emit: @Sendable (Observation) async throws -> Void) async throws {
        let revision = try revision(context, locator: nil)
        let nodes = try await listContent(in: context, under: nil, limit: 10_000)
        for node in nodes {
            try Task.checkCancellation()
            if let page = revision.pages.first(where: { $0.pageIndex == node.order && !$0.usesNativeText }) {
                // One page projection avoids exhausting the shared 10k-fragment budget on
                // ordinary long scanned books. Search offsets resolve back to real spans.
                try await emit(readFragment(in: context, at: revision.locator(page: page), maxCharacters: 1_048_576))
            } else if context.filenameExtension == "pdf" {
                try await emit(PDFAdapter().readFragment(in: context, at: node.locator, maxCharacters: 1_048_576))
            }
        }
    }

    func presentation(in context: AdapterContext, at locator: Locator?) async throws -> PresentationDocument {
        let revision = try revision(context, locator: locator)
        let requested: Locator
        if let locator { requested = locator }
        else if let page = revision.pages.first(where: { !$0.usesNativeText }) { requested = revision.locator(page: page) }
        else { return try await PDFAdapter().presentation(in: context, at: nil) }
        try context.validate(requested, adapterID: Self.id)
        _ = try await readFragment(in: context, at: requested, maxCharacters: 1_048_576)
        guard let page = revision.pages.first(where: { $0.pageIndex == requested.pdfPageIndex }) else { throw OCRError.missingRevision }
        let anchor = try enrichedLocator(requested, page: page)
        return PresentationDocument(id: "presentation:\(anchor.stableID)", surface: context.filenameExtension == "pdf" ? .pdfKit : .nativeImage,
            locator: anchor, title: context.source.displayName, mediaType: context.filenameExtension == "pdf" ? "application/pdf" : "image/\(context.filenameExtension)",
            content: nil, contentURL: context.managedURL, baseURL: nil, limitations: descriptor.limitations)
    }

    func resolve(_ locator: Locator, in context: AdapterContext) async throws -> LocatorResolution {
        guard locator.sourceID == context.source.id, locator.snapshotID == context.snapshot.id,
              locator.adapterID == Self.id, locator.schemaVersion == Locator.currentSchemaVersion else {
            return LocatorResolution(state: .orphaned, requested: locator, resolved: nil, reason: "识别证据属于其他快照，不能自动迁移")
        }
        do {
            _ = try await readFragment(in: context, at: locator, maxCharacters: 1_048_576)
            let revision = try revision(context, locator: locator)
            guard let page = revision.pages.first(where: { $0.pageIndex == locator.pdfPageIndex }) else { throw OCRError.missingRevision }
            return LocatorResolution(state: .current, requested: locator,
                resolved: try enrichedLocator(locator, page: page), reason: "原始快照及不可变识别版本一致")
        } catch {
            return LocatorResolution(state: .orphaned, requested: locator, resolved: nil, reason: "原识别版本或区域不可用")
        }
    }

    private func revision(_ context: AdapterContext, locator: Locator?) throws -> OCRRevision {
        if let locator, let id = locator.payload["ocrRevisionID"] {
            guard let value = try database.ocrRevision(id: id, sourceID: context.source.id, snapshotID: context.snapshot.id) else { throw OCRError.missingRevision }
            return value
        }
        guard let value = try database.activeOCRRevision(snapshotID: context.snapshot.id), value.sourceID == context.source.id else { throw OCRError.missingRevision }
        return value
    }

    private func nativeLocator(_ context: AdapterContext, pageIndex: Int) -> Locator {
        Locator(sourceID: context.source.id, snapshotID: context.snapshot.id,
            adapterID: context.filenameExtension == "pdf" ? PDFAdapter.id : ImageAdapter.id,
            payload: ["pageIndex": String(pageIndex)], structuralPath: "page/\(pageIndex)")
    }

    private func validatedText(_ text: String, locator: Locator) throws -> String {
        let value: String
        if locator.payload["startUTF16"] != nil || locator.payload["endUTF16"] != nil {
            guard let start = Int(locator.payload["startUTF16"] ?? ""),
                  let end = Int(locator.payload["endUTF16"] ?? ""), start >= 0, end > start,
                  end <= text.utf16.count,
                  let range = Range(NSRange(location: start, length: end - start), in: text) else { throw OCRError.missingRevision }
            value = String(text[range])
        } else { value = text }
        if let quote = locator.textQuote {
            guard value == quote.exact, locator.fingerprint == AdapterUtilities.sha256(value) else { throw OCRError.missingRevision }
        }
        return value
    }

    private func enrichedLocator(_ locator: Locator, page: OCRPage) throws -> Locator {
        guard locator.payload["ocrSpanID"] == nil,
              let start = Int(locator.payload["startUTF16"] ?? ""),
              let end = Int(locator.payload["endUTF16"] ?? "") else { return locator }
        var offset = 0
        var bounds = CGRect.null
        for span in page.spans.sorted(by: { $0.order < $1.order }) {
            let length = span.text.utf16.count
            if start < offset + length && end > offset { bounds = bounds.union(span.bounds.rect) }
            offset += length + 1
        }
        guard !bounds.isNull else { throw OCRError.missingRevision }
        let rectangle = OCRRectangle(bounds).locatorValue
        if let existing = locator.payload["rect"], existing != rectangle { throw OCRError.missingRevision }
        var payload = locator.payload; payload["rect"] = rectangle
        return Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID, adapterID: locator.adapterID,
            payload: payload, structuralPath: locator.structuralPath, textQuote: locator.textQuote, fingerprint: locator.fingerprint)
    }
}
