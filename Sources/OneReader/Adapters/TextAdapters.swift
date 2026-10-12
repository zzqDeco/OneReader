import Foundation
import Markdown

struct PlainTextAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, IndexingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.text"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.1",
        displayName: "Plain Text",
        probeRule: AdapterProbeRule(
            filenameExtensions: ["txt", "text", "log"],
            mediaTypes: ["text/plain"],
            sourceOrigins: [.localFile, .remoteURL]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["只保证 UTF-8 文本"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        try TextAdapterCore.probe(
            context,
            descriptor: descriptor,
            extensions: descriptor.probeRule.filenameExtensions,
            confidence: 0.9
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
        try TextAdapterCore.list(context, adapterID: descriptor.id, kind: .document, limit: limit)
    }

    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation {
        try TextAdapterCore.read(
            context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/plain",
            maxCharacters: maxCharacters
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        try TextAdapterCore.search(
            context,
            adapterID: descriptor.id,
            query: query,
            limit: limit
        )
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        try TextAdapterCore.presentation(
            context,
            adapterID: descriptor.id,
            surface: .nativeText,
            mediaType: "text/plain",
            locator: locator
        )
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        try TextAdapterCore.resolve(locator, in: context, adapterID: descriptor.id)
    }
}

struct CodeAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, IndexingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.code"
    static let extensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "java", "js", "jsx",
        "json", "kt", "kts", "m", "mm", "php", "py", "rb", "rs", "sh", "sql",
        "swift", "ts", "tsx", "xml", "yaml", "yml",
    ]

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.1",
        displayName: "Source Code",
        probeRule: AdapterProbeRule(
            filenameExtensions: extensions,
            mediaTypes: ["text/x-source", "application/json", "application/xml"],
            sourceOrigins: [.localFile]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["语法高亮由原生呈现层按扩展名选择"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        try TextAdapterCore.probe(
            context,
            descriptor: descriptor,
            extensions: Self.extensions,
            confidence: 0.94
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
        try TextAdapterCore.list(context, adapterID: descriptor.id, kind: .document, limit: limit)
    }

    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation {
        try TextAdapterCore.read(
            context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/x-source",
            maxCharacters: maxCharacters
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        try TextAdapterCore.search(
            context,
            adapterID: descriptor.id,
            query: query,
            limit: limit
        )
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        try TextAdapterCore.presentation(
            context,
            adapterID: descriptor.id,
            surface: .nativeCode,
            mediaType: "text/x-source",
            locator: locator
        )
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        try TextAdapterCore.resolve(locator, in: context, adapterID: descriptor.id)
    }
}

struct MarkdownAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, IndexingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.markdown"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.1",
        displayName: "Markdown",
        probeRule: AdapterProbeRule(
            filenameExtensions: ["md", "markdown", "mdown", "mkd"],
            mediaTypes: ["text/markdown"],
            sourceOrigins: [.localFile, .remoteURL]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["HTML 块按不可信内容处理"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        try TextAdapterCore.probe(
            context,
            descriptor: descriptor,
            extensions: descriptor.probeRule.filenameExtensions,
            confidence: 0.98
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
        let text = try TextAdapterCore.loadText(context.managedURL)
        let document = Document(parsing: text, source: context.managedURL)
        var collector = MarkdownHeadingCollector()
        collector.visit(document)
        let path = TextAdapterCore.locatorPath(context)
        let headings = collector.headings.prefix(max(1, limit)).enumerated().map { index, heading in
            let startLine = heading.range?.lowerBound.line
            let endLine = heading.range.map { max($0.lowerBound.line, $0.upperBound.line) }
            var payload = ["path": path, "headingLevel": String(heading.level)]
            if let startLine { payload["startLine"] = String(startLine) }
            if let endLine { payload["endLine"] = String(endLine) }
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: descriptor.id,
                payload: payload,
                structuralPath: heading.structuralPath,
                textQuote: TextQuote(prefix: nil, exact: heading.title, suffix: nil),
                fingerprint: AdapterUtilities.sha256(heading.title)
            )
            return ContentNode(
                id: locator.stableID,
                title: heading.title,
                kind: .section,
                locator: locator,
                depth: max(0, heading.level - 1),
                order: index,
                mediaType: "text/markdown",
                isReadable: true
            )
        }
        if !headings.isEmpty { return Array(headings) }
        return try TextAdapterCore.list(
            context,
            adapterID: descriptor.id,
            kind: .document,
            limit: limit
        )
    }

    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation {
        try TextAdapterCore.read(
            context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/markdown",
            maxCharacters: maxCharacters
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        try TextAdapterCore.search(
            context,
            adapterID: descriptor.id,
            query: query,
            limit: limit
        )
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        try TextAdapterCore.presentation(
            context,
            adapterID: descriptor.id,
            surface: .nativeMarkdown,
            mediaType: "text/markdown",
            locator: locator
        )
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        try TextAdapterCore.resolve(locator, in: context, adapterID: descriptor.id)
    }
}

extension PlainTextAdapter {
    func indexContent(
        in context: AdapterContext,
        emit: @Sendable (Observation) async throws -> Void
    ) async throws {
        try await TextAdapterCore.index(
            context, adapterID: descriptor.id, mediaType: "text/plain", emit: emit
        )
    }
}

extension CodeAdapter {
    func indexContent(
        in context: AdapterContext,
        emit: @Sendable (Observation) async throws -> Void
    ) async throws {
        try await TextAdapterCore.index(
            context, adapterID: descriptor.id, mediaType: "text/x-source", emit: emit
        )
    }
}

extension MarkdownAdapter {
    func indexContent(
        in context: AdapterContext,
        emit: @Sendable (Observation) async throws -> Void
    ) async throws {
        try await TextAdapterCore.index(
            context, adapterID: descriptor.id, mediaType: "text/markdown", emit: emit
        )
    }
}

private struct MarkdownHeadingCollector: MarkupWalker {
    struct HeadingValue {
        let title: String
        let level: Int
        let range: SourceRange?
        let structuralPath: String
    }

    var headings: [HeadingValue] = []
    private var headingCounts: [Int: Int] = [:]

    mutating func visitHeading(_ heading: Heading) -> () {
        let next = (headingCounts[heading.level] ?? 0) + 1
        headingCounts[heading.level] = next
        for deeper in Array(headingCounts.keys) where deeper > heading.level {
            headingCounts[deeper] = nil
        }
        let path = (1...heading.level).compactMap { level in
            headingCounts[level].map { "h\(level)[\($0)]" }
        }.joined(separator: "/")
        headings.append(
            HeadingValue(
                title: heading.plainText,
                level: heading.level,
                range: heading.range,
                structuralPath: path
            )
        )
    }
}

enum TextAdapterCore {
    static let maximumTextBytes = 64 * 1_024 * 1_024
    static let indexChunkCharacters = 64 * 1_024
    static let indexOverlapCharacters = 512

    static func probe(
        _ context: AdapterContext,
        descriptor: AdapterDescriptor,
        extensions: Set<String>,
        confidence: Double
    ) throws -> AdapterProbeMatch? {
        guard !isDirectory(context.managedURL) else { return nil }
        let extensionMatches = extensions.contains(context.filenameExtension)
        let mediaMatches = context.declaredMediaType.map {
            descriptor.probeRule.mediaTypes.contains($0)
        } ?? false
        guard extensionMatches || mediaMatches else { return nil }
        _ = try loadText(context.managedURL)
        let evidence = ProbeEvidence(
            id: "\(descriptor.id):text-probe",
            adapterID: descriptor.id,
            rule: extensionMatches ? "filename-extension" : "media-type",
            detail: extensionMatches ? context.filenameExtension : context.declaredMediaType ?? "",
            confidence: confidence
        )
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: confidence,
            evidence: [evidence],
            reason: "UTF-8 文本与声明格式匹配"
        )
    }

    static func verifyRevision(_ context: AdapterContext) throws {
        guard context.snapshot.revisionKind == .contentDigest else { return }
        let data = try Data(contentsOf: context.managedURL, options: [.mappedIfSafe])
        guard AdapterUtilities.sha256(data) == context.snapshot.revision else {
            throw AdapterError.unsupportedContent("托管文本 digest 与 Snapshot 不一致")
        }
    }

    static func list(
        _ context: AdapterContext,
        adapterID: String,
        kind: ContentNodeKind,
        limit: Int
    ) throws -> [ContentNode] {
        guard limit > 0 else { return [] }
        let locator = rootLocator(context, adapterID: adapterID)
        return [
            ContentNode(
                id: locator.stableID,
                title: context.source.displayName,
                kind: kind,
                locator: locator,
                depth: 0,
                order: 0,
                mediaType: nil,
                isReadable: true
            )
        ]
    }

    static func index(
        _ context: AdapterContext,
        adapterID: String,
        mediaType: String,
        chunkCharacters: Int = indexChunkCharacters,
        overlapCharacters: Int = indexOverlapCharacters,
        emit: @Sendable (Observation) async throws -> Void
    ) async throws {
        let text = try loadText(context.managedURL)
        let chunkSize = max(1, chunkCharacters)
        let overlap = min(max(0, overlapCharacters), chunkSize - 1)
        let path = locatorPath(context)
        var lower = text.startIndex
        var utf16Offset = 0
        var line = 1
        repeat {
            try Task.checkCancellation()
            let upper = text.index(lower, offsetBy: chunkSize, limitedBy: text.endIndex)
                ?? text.endIndex
            let body = String(text[lower..<upper])
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: adapterID,
                payload: [
                    "path": path,
                    "indexTextRange": "utf16",
                    "startUTF16": String(utf16Offset),
                    "endUTF16": String(utf16Offset + body.utf16.count),
                    "startLine": String(line),
                    "endLine": String(line + lineBreakCount(body)),
                ],
                structuralPath: path,
                textQuote: body.isEmpty ? nil : TextQuote(
                    prefix: nil, exact: String(body.prefix(160)), suffix: nil
                ),
                fingerprint: AdapterUtilities.sha256(body)
            )
            try await emit(AdapterUtilities.makeObservation(
                context: context,
                adapterID: adapterID,
                locator: locator,
                mediaType: mediaType,
                content: body,
                maxCharacters: chunkSize
            ))
            guard upper != text.endIndex else { break }
            let next = text.index(upper, offsetBy: -overlap)
            let advanced = text[lower..<next]
            utf16Offset += advanced.utf16.count
            line += lineBreakCount(advanced)
            lower = next
        } while lower < text.endIndex
    }

    static func read(
        _ context: AdapterContext,
        adapterID: String,
        locator: Locator,
        mediaType: String,
        maxCharacters: Int
    ) throws -> Observation {
        try context.validate(locator, adapterID: adapterID)
        let text = try loadText(context.managedURL)
        let selected: String
        if locator.payload["indexTextRange"] == "utf16",
           locator.payload["positionKind"] != "textViewport" {
            guard let start = locator.payload["startUTF16"].flatMap(Int.init),
                  let end = locator.payload["endUTF16"].flatMap(Int.init),
                  start >= 0, end >= start, end <= text.utf16.count,
                  let range = Range(NSRange(location: start, length: end - start), in: text),
                  range.lowerBound.samePosition(in: text) != nil,
                  range.upperBound.samePosition(in: text) != nil else {
                throw AdapterError.invalidLocator("索引文本范围超出内容或切断 Unicode 字符")
            }
            selected = String(text[range])
        } else if let lines = locator.lineRange {
            let allLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let lower = max(1, lines.lowerBound)
            let upper = min(allLines.count, lines.upperBound)
            guard lower <= upper else {
                throw AdapterError.invalidLocator("行范围超出文本")
            }
            selected = allLines[(lower - 1)...(upper - 1)].joined(separator: "\n")
        } else {
            selected = text
        }
        return AdapterUtilities.makeObservation(
            context: context,
            adapterID: adapterID,
            locator: locator,
            mediaType: mediaType,
            content: selected,
            maxCharacters: maxCharacters
        )
    }

    static func search(
        _ context: AdapterContext,
        adapterID: String,
        query: String,
        limit: Int
    ) throws -> [ContentSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let text = try loadText(context.managedURL)
        var searchRange = text.startIndex..<text.endIndex
        var hits: [ContentSearchHit] = []
        while hits.count < limit,
              let range = text.range(of: needle, options: [.caseInsensitive], range: searchRange) {
            try Task.checkCancellation()
            let prefix = text[..<range.lowerBound]
            let line = 1 + lineBreakCount(prefix)
            let quote = AdapterUtilities.excerpt(from: text, matching: range)
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: adapterID,
                payload: ["path": locatorPath(context), "startLine": String(line)],
                structuralPath: locatorPath(context),
                textQuote: TextQuote(prefix: nil, exact: String(text[range]), suffix: nil),
                fingerprint: AdapterUtilities.sha256(quote)
            )
            hits.append(
                ContentSearchHit(
                    id: "\(locator.stableID):\(hits.count)",
                    sourceID: context.source.id,
                    snapshotID: context.snapshot.id,
                    adapterID: adapterID,
                    locator: locator,
                    title: context.source.displayName,
                    context: quote,
                    rank: 1 / Double(hits.count + 1)
                )
            )
            searchRange = range.upperBound..<text.endIndex
        }
        return hits
    }

    static func presentation(
        _ context: AdapterContext,
        adapterID: String,
        surface: PresentationSurface,
        mediaType: String,
        locator: Locator?
    ) throws -> PresentationDocument {
        let resolvedLocator = locator ?? rootLocator(context, adapterID: adapterID)
        try context.validate(resolvedLocator, adapterID: adapterID)
        let content = try loadText(context.managedURL)
        let resourceRoot = isDirectory(context.contentRootURL)
            ? context.contentRootURL
            : context.managedURL.deletingLastPathComponent()
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: surface,
            locator: resolvedLocator,
            title: context.source.displayName,
            mediaType: mediaType,
            content: content,
            contentURL: context.managedURL,
            baseURL: resourceRoot,
            limitations: []
        )
    }

    static func resolve(
        _ locator: Locator,
        in context: AdapterContext,
        adapterID: String
    ) throws -> LocatorResolution {
        guard locator.sourceID == context.source.id,
              locator.adapterID == adapterID,
              locator.schemaVersion == Locator.currentSchemaVersion else {
            throw AdapterError.invalidLocator("Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }

        let text = try loadText(context.managedURL)
        let currentPath = locatorPath(context)
        let structuralMatch = locator.relativePath == currentPath
        let quoteRange = try matchingQuote(in: text, locator: locator)
        let requiresQuoteRelocation = locator.lineRange != nil
        guard requiresQuoteRelocation ? quoteRange != nil : structuralMatch || quoteRange != nil else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新 Snapshot 中未找到结构路径或精确 quote"
            )
        }
        var payload = locator.payload
        payload["path"] = currentPath
        if let quoteRange, locator.lineRange != nil {
            let startLine = 1 + lineBreakCount(text[..<quoteRange.lowerBound])
            let endLine = startLine + lineBreakCount(text[quoteRange])
            payload["startLine"] = String(startLine)
            payload["endLine"] = String(endLine)
            if locator.payload["indexTextRange"] == "utf16" {
                let range = NSRange(quoteRange, in: text)
                payload["startUTF16"] = String(range.location)
                payload["endUTF16"] = String(NSMaxRange(range))
            }
        }
        let relocated = Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: adapterID,
            payload: payload,
            structuralPath: locator.structuralPath,
            textQuote: locator.textQuote,
            fingerprint: locator.fingerprint
        )
        return LocatorResolution(
            state: .relocated,
            requested: locator,
            resolved: relocated,
            reason: quoteRange != nil ? "精确 quote 已在新文本中重新定位" : "结构路径仍存在"
        )
    }

    /// Swift Character treats CRLF as one grapheme, just like one source line break.
    static func lineBreakCount(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
    }

    private static func matchingQuote(in text: String, locator: Locator) throws -> Range<String.Index>? {
        guard let quote = locator.textQuote, !quote.exact.isEmpty else { return nil }
        let originalOffset = locator.payload["startUTF16"].flatMap(Int.init)
        var searchRange = text.startIndex..<text.endIndex
        var best: Range<String.Index>?
        var bestContext = -1
        var bestDistance = Int.max
        var tied = false
        while let range = text.range(of: quote.exact, range: searchRange) {
            try Task.checkCancellation()
            let context = (quote.prefix.map { text[..<range.lowerBound].hasSuffix($0) ? 1 : 0 } ?? 0)
                + (quote.suffix.map { text[range.upperBound...].hasPrefix($0) ? 1 : 0 } ?? 0)
            let distance = originalOffset.map {
                abs(NSRange(range, in: text).location - max(0, $0))
            } ?? 0
            if context > bestContext || (context == bestContext && distance < bestDistance) {
                best = range
                bestContext = context
                bestDistance = distance
                tied = false
            } else if context == bestContext && distance == bestDistance {
                tied = true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        // Never silently map an ambiguous repeated quote to its first occurrence.
        return tied ? nil : best
    }

    static func loadText(
        _ url: URL,
        maximumBytes: Int = maximumTextBytes
    ) throws -> String {
        let safeLimit = max(1, maximumBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: safeLimit + 1) ?? Data()
        guard data.count <= safeLimit else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? Int64(data.count)
            throw AdapterError.textSizeLimit(limit: safeLimit, actual: size)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AdapterError.unreadableText(url.path)
        }
        return text
    }

    static func rootLocator(_ context: AdapterContext, adapterID: String) -> Locator {
        Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: adapterID,
            payload: ["path": locatorPath(context)],
            structuralPath: locatorPath(context),
            textQuote: nil,
            fingerprint: context.snapshot.digest
        )
    }

    static func locatorPath(_ context: AdapterContext) -> String {
        let root = context.contentRootURL.standardizedFileURL.pathComponents
        let candidate = context.managedURL.standardizedFileURL.pathComponents
        if candidate.count > root.count, candidate.starts(with: root) {
            return candidate.dropFirst(root.count).joined(separator: "/")
        }
        return context.source.displayName
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
