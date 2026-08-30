import Foundation
import SwiftSoup

struct SanitizedHTML: Sendable {
    struct Heading: Sendable {
        let title: String
        let level: Int
        let selector: String
    }

    let title: String
    let documentHTML: String
    let plainText: String
    let headings: [Heading]
}

enum HTMLSanitizer {
    static func sanitize(
        _ html: String,
        baseURL: URL?,
        managedDocumentURL: URL? = nil,
        managedResourceRoot: URL? = nil
    ) throws -> SanitizedHTML {
        do {
            let preparedHTML: String
            if let managedDocumentURL, let managedResourceRoot {
                preparedHTML = try rewriteManagedResources(
                    in: html,
                    documentURL: managedDocumentURL,
                    rootURL: managedResourceRoot
                )
            } else {
                preparedHTML = html
            }
            let document = try SwiftSoup.parse(preparedHTML, baseURL?.absoluteString ?? "")
            let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
            try document.select(
                "script,style,iframe,frame,object,embed,form,input,button,textarea,select,video,audio,svg,math,link,meta,base"
            ).remove()
            let whitelist = try Whitelist.relaxed()
                .addProtocols("img", "src", "onereader-content", "data")
                .preserveRelativeLinks(true)
            let bodyHTML = try document.body()?.html() ?? ""
            let cleanedBody = try SwiftSoup.clean(
                bodyHTML,
                baseURL?.absoluteString ?? "",
                whitelist
            ) ?? ""
            let cleanedDocument = try SwiftSoup.parseBodyFragment(
                cleanedBody,
                baseURL?.absoluteString ?? ""
            )
            let headings = try cleanedDocument.select("h1,h2,h3,h4,h5,h6").array().map {
                SanitizedHTML.Heading(
                    title: try $0.text(),
                    level: Int(String($0.tagName().dropFirst())) ?? 1,
                    selector: try $0.cssSelector()
                )
            }
            let plainText = try cleanedDocument.text()
            let escapedTitle = escape(title.isEmpty ? "OneReader" : title)
            let wrapped = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src onereader-content: data:; style-src 'unsafe-inline'; font-src onereader-content:; media-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none';">
                  <title>\(escapedTitle)</title>
                </head>
                <body>\(cleanedBody)</body>
                </html>
                """
            return SanitizedHTML(
                title: title,
                documentHTML: wrapped,
                plainText: plainText,
                headings: headings
            )
        } catch {
            throw AdapterError.unsafeHTML(error.localizedDescription)
        }
    }

    private static func rewriteManagedResources(
        in html: String,
        documentURL: URL,
        rootURL: URL
    ) throws -> String {
        let document = try SwiftSoup.parse(html)
        let root = rootURL.standardizedFileURL
        let baseDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        for element in try document.select("[src]").array() {
            let raw = try element.attr("src")
            if raw.lowercased().hasPrefix("data:") { continue }
            guard URL(string: raw)?.scheme == nil, !raw.hasPrefix("/"), !raw.contains("\\") else {
                try element.removeAttr("src")
                continue
            }
            let fragmentFree = raw.split(separator: "#", maxSplits: 1)
                .first.map(String.init) ?? raw
            let queryFree = fragmentFree.split(separator: "?", maxSplits: 1)
                .first.map(String.init) ?? fragmentFree
            let decoded = queryFree.removingPercentEncoding ?? queryFree
            let resourceURL = baseDirectory.appendingPathComponent(decoded).standardizedFileURL
            guard resourceURL.pathComponents.starts(with: root.pathComponents),
                  let values = try? resourceURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                try element.removeAttr("src")
                continue
            }
            let relativePath = resourceURL.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#")
            let encodedPath = relativePath.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
            }.joined(separator: "/")
            try element.attr("src", "onereader-content:/\(encodedPath)")
        }
        return try document.outerHtml()
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct HTMLAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.html"
    private static let extensions: Set<String> = ["html", "htm", "xhtml"]

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "Sanitized HTML",
        probeRule: AdapterProbeRule(
            filenameExtensions: extensions,
            mediaTypes: ["text/html", "application/xhtml+xml"],
            sourceOrigins: [.localFile, .remoteURL]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["脚本、表单、内嵌框架和自动网络请求被禁用"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard !TextAdapterCore.isDirectory(context.managedURL) else { return nil }
        let extensionMatches = Self.extensions.contains(context.filenameExtension)
        let mediaMatches = context.declaredMediaType.map {
            descriptor.probeRule.mediaTypes.contains($0)
        } ?? false
        guard extensionMatches || mediaMatches else { return nil }
        let html = try TextAdapterCore.loadText(context.managedURL)
        _ = try HTMLSanitizer.sanitize(html, baseURL: context.source.originURL)
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: 0.98,
            evidence: [
                ProbeEvidence(
                    id: "\(descriptor.id):html",
                    adapterID: descriptor.id,
                    rule: extensionMatches ? "filename-extension" : "media-type",
                    detail: extensionMatches ? context.filenameExtension : context.declaredMediaType ?? "",
                    confidence: 0.98
                )
            ],
            reason: "HTML 可解析并可净化为受控文档"
        )
    }

    func verifyRevision(in context: AdapterContext) async throws {
        try TextAdapterCore.verifyRevision(context)
    }

    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode] {
        let sanitized = try sanitized(context)
        if sanitized.headings.isEmpty {
            return try TextAdapterCore.list(
                context,
                adapterID: descriptor.id,
                kind: .document,
                limit: limit
            )
        }
        return sanitized.headings.prefix(max(1, limit)).enumerated().map { order, heading in
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: descriptor.id,
                payload: [
                    "path": TextAdapterCore.locatorPath(context),
                    "domPath": heading.selector,
                ],
                structuralPath: heading.selector,
                textQuote: TextQuote(prefix: nil, exact: heading.title, suffix: nil),
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
        let sanitized = try sanitized(context)
        var content = sanitized.plainText
        if let quote = locator.textQuote?.exact,
           let range = content.range(of: quote, options: [.caseInsensitive]) {
            content = AdapterUtilities.excerpt(from: content, matching: range, radius: 1_000)
        }
        return AdapterUtilities.makeObservation(
            context: context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/plain; source=text/html",
            content: content,
            maxCharacters: maxCharacters
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        let sanitized = try sanitized(context)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var range = sanitized.plainText.startIndex..<sanitized.plainText.endIndex
        var hits: [ContentSearchHit] = []
        while hits.count < limit,
              let match = sanitized.plainText.range(
                of: needle,
                options: [.caseInsensitive],
                range: range
              ) {
            try Task.checkCancellation()
            let excerpt = AdapterUtilities.excerpt(from: sanitized.plainText, matching: match)
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: descriptor.id,
                payload: ["path": TextAdapterCore.locatorPath(context)],
                structuralPath: TextAdapterCore.locatorPath(context),
                textQuote: TextQuote(
                    prefix: nil,
                    exact: String(sanitized.plainText[match]),
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
                    title: sanitized.title.isEmpty ? context.source.displayName : sanitized.title,
                    context: excerpt,
                    rank: 1 / Double(hits.count + 1)
                )
            )
            range = match.upperBound..<sanitized.plainText.endIndex
        }
        return hits
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        let sanitized = try sanitized(context)
        let resolvedLocator = locator ?? TextAdapterCore.rootLocator(
            context,
            adapterID: descriptor.id
        )
        try context.validate(resolvedLocator, adapterID: descriptor.id)
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: .sanitizedWeb,
            locator: resolvedLocator,
            title: sanitized.title.isEmpty ? context.source.displayName : sanitized.title,
            mediaType: "text/html",
            content: sanitized.documentHTML,
            contentURL: nil,
            baseURL: context.managedURL.deletingLastPathComponent(),
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
            throw AdapterError.invalidLocator("HTML Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        let sanitized = try sanitized(context)
        let quoteMatches = locator.textQuote.map {
            sanitized.plainText.contains($0.exact)
        } ?? false
        let domPath = locator.payload["domPath"]
        let domMatches: Bool
        if let domPath {
            let document = try SwiftSoup.parse(sanitized.documentHTML)
            domMatches = try !document.select(domPath).isEmpty()
        } else {
            domMatches = false
        }
        guard domMatches || quoteMatches else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新 Snapshot 中 DOM path 与 quote 均不可用"
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
            reason: domMatches ? "DOM path 仍存在" : "精确 quote 仍存在"
        )
    }

    private func sanitized(_ context: AdapterContext) throws -> SanitizedHTML {
        let root = TextAdapterCore.isDirectory(context.contentRootURL)
            ? context.contentRootURL
            : context.managedURL.deletingLastPathComponent()
        return try HTMLSanitizer.sanitize(
            TextAdapterCore.loadText(context.managedURL),
            baseURL: context.source.originURL,
            managedDocumentURL: context.managedURL,
            managedResourceRoot: root
        )
    }
}
