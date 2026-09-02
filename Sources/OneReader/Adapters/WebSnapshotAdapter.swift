import Foundation
import SwiftSoup

struct WebSnapshotAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.web-snapshot"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "Web Snapshot",
        probeRule: AdapterProbeRule(
            filenameExtensions: [],
            mediaTypes: ["text/html", "application/xhtml+xml"],
            sourceOrigins: [.remoteURL]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: [
            "脚本、表单、跨来源资源和自动外链被禁用",
            "仅使用导入时缓存的同源资源",
        ]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard context.source.originKind == .remoteURL,
              TextAdapterCore.isDirectory(context.managedURL),
              FileManager.default.fileExists(atPath: manifestURL(context).path),
              FileManager.default.fileExists(atPath: indexURL(context).path) else {
            return nil
        }
        let manifest = try loadManifest(context)
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: 1,
            evidence: [
                ProbeEvidence(
                    id: "\(descriptor.id):manifest",
                    adapterID: descriptor.id,
                    rule: "managed-web-snapshot",
                    detail: manifest.finalURL.absoluteString,
                    confidence: 1
                )
            ],
            reason: "托管网页快照包含可验证 manifest、净化正文和同源资源缓存"
        )
    }

    func verifyRevision(in context: AdapterContext) async throws {
        guard context.snapshot.revisionKind == .webSnapshot,
              !context.snapshot.revision.isEmpty else {
            throw AdapterError.unsupportedContent("网页快照 revision 不完整")
        }
        _ = try loadManifest(context)
        _ = try sanitized(context)
    }

    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode] {
        let page = try sanitized(context)
        if page.headings.isEmpty {
            let root = makeLocator(context)
            return [
                ContentNode(
                    id: root.stableID,
                    title: page.title.isEmpty ? context.source.displayName : page.title,
                    kind: .document,
                    locator: root,
                    depth: 0,
                    order: 0,
                    mediaType: "text/html",
                    isReadable: true
                )
            ]
        }
        return page.headings.prefix(max(1, limit)).enumerated().map { order, heading in
            let locator = makeLocator(
                context,
                domPath: heading.selector,
                quote: TextQuote(prefix: nil, exact: heading.title, suffix: nil),
                fingerprint: AdapterUtilities.sha256(heading.title)
            )
            return ContentNode(
                id: locator.stableID,
                title: heading.title,
                kind: .section,
                locator: locator,
                depth: max(0, heading.level - 1),
                order: order,
                mediaType: "text/html",
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
        let page = try sanitized(context)
        var content = page.plainText
        if let exact = locator.textQuote?.exact,
           let range = content.range(of: exact, options: [.caseInsensitive]) {
            content = AdapterUtilities.excerpt(from: content, matching: range, radius: 1_000)
        }
        return AdapterUtilities.makeObservation(
            context: context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/plain; source=text/html",
            content: content,
            maxCharacters: maxCharacters,
            contentReference: "index.html"
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let page = try sanitized(context)
        var remaining = page.plainText.startIndex..<page.plainText.endIndex
        var hits: [ContentSearchHit] = []
        while hits.count < min(max(1, limit), 20),
              let match = page.plainText.range(
                of: needle,
                options: [.caseInsensitive],
                range: remaining
              ) {
            try Task.checkCancellation()
            let excerpt = AdapterUtilities.excerpt(from: page.plainText, matching: match)
            let locator = makeLocator(
                context,
                quote: TextQuote(
                    prefix: nil,
                    exact: String(page.plainText[match]),
                    suffix: nil
                ),
                fingerprint: AdapterUtilities.sha256(excerpt)
            )
            hits.append(
                ContentSearchHit(
                    id: "\(locator.stableID):\(hits.count)",
                    sourceID: context.source.id,
                    snapshotID: context.snapshot.id,
                    adapterID: descriptor.id,
                    locator: locator,
                    title: page.title.isEmpty ? context.source.displayName : page.title,
                    context: excerpt,
                    rank: 1 / Double(hits.count + 1)
                )
            )
            remaining = match.upperBound..<page.plainText.endIndex
        }
        return hits
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        let page = try sanitized(context)
        let resolved = locator ?? makeLocator(context)
        try context.validate(resolved, adapterID: descriptor.id)
        return PresentationDocument(
            id: "presentation:\(resolved.stableID)",
            surface: .sanitizedWeb,
            locator: resolved,
            title: page.title.isEmpty ? context.source.displayName : page.title,
            mediaType: "text/html",
            content: page.documentHTML,
            contentURL: indexURL(context),
            baseURL: context.managedURL,
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
            throw AdapterError.invalidLocator("Web Snapshot Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        let page = try sanitized(context)
        let quoteMatches = locator.textQuote.map { page.plainText.contains($0.exact) } ?? false
        let domMatches: Bool
        if let domPath = locator.payload["domPath"] {
            let document = try SwiftSoup.parse(page.documentHTML)
            domMatches = try !document.select(domPath).isEmpty()
        } else {
            domMatches = false
        }
        guard domMatches || quoteMatches || locator.textQuote == nil else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新网页快照中 DOM path 与 quote 均不可用"
            )
        }
        return LocatorResolution(
            state: .relocated,
            requested: locator,
            resolved: makeLocator(
                context,
                domPath: locator.payload["domPath"],
                quote: locator.textQuote,
                fingerprint: locator.fingerprint
            ),
            reason: domMatches ? "DOM path 仍存在" : "精确 quote 或文档根仍可定位"
        )
    }

    private func makeLocator(
        _ context: AdapterContext,
        domPath: String? = nil,
        quote: TextQuote? = nil,
        fingerprint: String? = nil
    ) -> Locator {
        var payload = ["path": "index.html"]
        if let domPath { payload["domPath"] = domPath }
        return Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: payload,
            structuralPath: domPath ?? "index.html",
            textQuote: quote,
            fingerprint: fingerprint ?? context.snapshot.digest
        )
    }

    private func loadManifest(_ context: AdapterContext) throws -> WebSnapshotManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            WebSnapshotManifest.self,
            from: Data(contentsOf: manifestURL(context))
        )
        guard manifest.schemaVersion == WebSnapshotManifest.schemaVersion else {
            throw AdapterError.unsupportedContent(
                "Web Snapshot manifest schema \(manifest.schemaVersion)"
            )
        }
        return manifest
    }

    private func sanitized(_ context: AdapterContext) throws -> SanitizedHTML {
        let manifest = try loadManifest(context)
        return try HTMLSanitizer.sanitize(
            TextAdapterCore.loadText(indexURL(context)),
            baseURL: manifest.finalURL,
            managedDocumentURL: indexURL(context),
            managedResourceRoot: context.managedURL
        )
    }

    private func manifestURL(_ context: AdapterContext) -> URL {
        context.managedURL.appendingPathComponent(WebSnapshotManifest.filename)
    }

    private func indexURL(_ context: AdapterContext) -> URL {
        context.managedURL.appendingPathComponent("index.html")
    }
}
