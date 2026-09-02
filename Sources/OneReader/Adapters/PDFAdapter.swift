import Foundation
import PDFKit

struct PDFAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.pdf"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "PDFKit",
        probeRule: AdapterProbeRule(
            filenameExtensions: ["pdf"],
            mediaTypes: ["application/pdf"],
            sourceOrigins: [.localFile, .remoteURL],
            magicPrefixes: [Data("%PDF-".utf8)]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["扫描件没有文本时不提供 OCR"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard !TextAdapterCore.isDirectory(context.managedURL) else { return nil }
        let handle = try FileHandle(forReadingFrom: context.managedURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 5) ?? Data()
        let extensionMatches = context.filenameExtension == "pdf"
        let magicMatches = prefix.starts(with: Data("%PDF-".utf8))
        guard extensionMatches || magicMatches else { return nil }
        guard PDFDocument(url: context.managedURL) != nil else {
            throw AdapterError.unsupportedContent("PDFKit 无法打开文件")
        }
        let confidence = magicMatches ? 1.0 : 0.96
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: confidence,
            evidence: [
                ProbeEvidence(
                    id: "\(descriptor.id):pdf-signature",
                    adapterID: descriptor.id,
                    rule: magicMatches ? "magic-prefix" : "filename-extension",
                    detail: magicMatches ? "%PDF-" : context.filenameExtension,
                    confidence: confidence
                )
            ],
            reason: "PDF signature 或扩展名通过，PDFKit 可打开"
        )
    }

    func verifyRevision(in context: AdapterContext) async throws {
        guard context.snapshot.revisionKind == .contentDigest else { return }
        let data = try Data(contentsOf: context.managedURL, options: [.mappedIfSafe])
        guard AdapterUtilities.sha256(data) == context.snapshot.revision else {
            throw AdapterError.unsupportedContent("PDF digest 与 Snapshot 不一致")
        }
    }

    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode] {
        let document = try loadDocument(context)
        var outlinedTitles: [Int: (title: String, depth: Int)] = [:]
        if let root = document.outlineRoot {
            var entries: [(title: String, pageIndex: Int, depth: Int)] = []
            collectOutline(root, document: document, depth: 0, entries: &entries)
            for entry in entries where outlinedTitles[entry.pageIndex] == nil {
                outlinedTitles[entry.pageIndex] = (entry.title, entry.depth)
            }
        }
        return (0..<document.pageCount)
            .prefix(max(1, limit))
            .enumerated()
            .map { order, pageIndex in
                let outline = outlinedTitles[pageIndex]
                let title = outline?.title ?? "第 \(pageIndex + 1) 页"
                let locator = pageLocator(
                    context,
                    pageIndex: pageIndex,
                    title: title
                )
                return ContentNode(
                    id: locator.stableID,
                    title: title,
                    kind: .page,
                    locator: locator,
                    depth: outline?.depth ?? 0,
                    order: order,
                    mediaType: "application/pdf",
                    isReadable: true
                )
            }
    }

    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation {
        try context.validate(locator, adapterID: descriptor.id)
        let document = try loadDocument(context)
        let pageIndex = locator.pdfPageIndex ?? 0
        guard pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            throw AdapterError.invalidLocator("PDF 页码超出范围")
        }
        let text = page.string ?? ""
        return AdapterUtilities.makeObservation(
            context: context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/plain; source=application/pdf",
            content: text,
            maxCharacters: maxCharacters,
            contentReference: context.snapshot.managedRelativePath
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let document = try loadDocument(context)
        var hits: [ContentSearchHit] = []
        for pageIndex in 0..<document.pageCount where hits.count < limit {
            try Task.checkCancellation()
            guard let text = document.page(at: pageIndex)?.string,
                  let range = text.range(of: needle, options: [.caseInsensitive]) else {
                continue
            }
            let quote = AdapterUtilities.excerpt(from: text, matching: range)
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: descriptor.id,
                payload: ["pageIndex": String(pageIndex)],
                structuralPath: "page/\(pageIndex)",
                textQuote: TextQuote(prefix: nil, exact: String(text[range]), suffix: nil),
                fingerprint: AdapterUtilities.sha256(quote)
            )
            hits.append(
                ContentSearchHit(
                    id: "\(locator.stableID):search",
                    sourceID: context.source.id,
                    snapshotID: context.snapshot.id,
                    adapterID: descriptor.id,
                    locator: locator,
                    title: "第 \(pageIndex + 1) 页",
                    context: quote,
                    rank: 1 / Double(hits.count + 1)
                )
            )
        }
        return hits
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        _ = try loadDocument(context)
        let resolvedLocator = locator ?? pageLocator(context, pageIndex: 0, title: nil)
        try context.validate(resolvedLocator, adapterID: descriptor.id)
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: .pdfKit,
            locator: resolvedLocator,
            title: context.source.displayName,
            mediaType: "application/pdf",
            content: nil,
            contentURL: context.managedURL,
            baseURL: nil,
            limitations: descriptor.limitations
        )
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        guard locator.sourceID == context.source.id,
              locator.adapterID == descriptor.id,
              locator.schemaVersion == Locator.currentSchemaVersion else {
            throw AdapterError.invalidLocator("PDF Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            try context.validate(locator, adapterID: descriptor.id)
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        let document = try loadDocument(context)
        guard let pageIndex = locator.pdfPageIndex,
              pageIndex >= 0,
              pageIndex < document.pageCount else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新 Snapshot 中页码不存在"
            )
        }
        if let quote = locator.textQuote?.exact,
           document.page(at: pageIndex)?.string?.contains(quote) != true {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "页码仍存在，但精确 quote 不匹配"
            )
        }
        let relocated = Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: locator.payload,
            structuralPath: locator.structuralPath,
            textQuote: locator.textQuote,
            fingerprint: locator.fingerprint
        )
        return LocatorResolution(
            state: .relocated,
            requested: locator,
            resolved: relocated,
            reason: "页码与 quote 在新 Snapshot 中仍有效"
        )
    }

    private func loadDocument(_ context: AdapterContext) throws -> PDFDocument {
        guard let document = PDFDocument(url: context.managedURL) else {
            throw AdapterError.unsupportedContent("PDFKit 无法打开托管 Snapshot")
        }
        return document
    }

    private func pageLocator(
        _ context: AdapterContext,
        pageIndex: Int,
        title: String?
    ) -> Locator {
        Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: ["pageIndex": String(pageIndex)],
            structuralPath: "page/\(pageIndex)",
            textQuote: title.map { TextQuote(prefix: nil, exact: $0, suffix: nil) },
            fingerprint: nil
        )
    }

    private func collectOutline(
        _ outline: PDFOutline,
        document: PDFDocument,
        depth: Int,
        entries: inout [(title: String, pageIndex: Int, depth: Int)]
    ) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if let page = child.destination?.page,
               let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                let pageIndex = document.index(for: page)
                if pageIndex >= 0 {
                    entries.append((title, pageIndex, depth))
                }
            }
            collectOutline(child, document: document, depth: depth + 1, entries: &entries)
        }
    }
}
