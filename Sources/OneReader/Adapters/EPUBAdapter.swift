import Foundation
import SwiftSoup
import ZIPFoundation

struct EPUBExtractionPolicy: Sendable {
    static let production = EPUBExtractionPolicy(
        maximumExpandedBytes: 4 * 1_024 * 1_024 * 1_024,
        expansionRatio: 10
    )

    let maximumExpandedBytes: UInt64
    let expansionRatio: UInt64
}

struct EPUBAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.epub"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "EPUB",
        probeRule: AdapterProbeRule(
            filenameExtensions: ["epub"],
            mediaTypes: ["application/epub+zip"],
            sourceOrigins: [.localFile, .remoteURL],
            magicPrefixes: [Data([0x50, 0x4b, 0x03, 0x04])]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["脚本和跨来源资源被禁用", "不执行 EPUB 内嵌交互"]
    )

    private let policy: EPUBExtractionPolicy

    init(policy: EPUBExtractionPolicy = .production) {
        self.policy = policy
    }

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard !TextAdapterCore.isDirectory(context.managedURL) else { return nil }
        let extensionMatches = context.filenameExtension == "epub"
        let mediaMatches = context.declaredMediaType == "application/epub+zip"
        guard extensionMatches || mediaMatches else { return nil }
        let archive = try Archive(url: context.managedURL, accessMode: .read)
        let mimetype = try archive["mimetype"].map { try readEntry($0, from: archive, limit: 128) }
        let mimetypeText = mimetype.flatMap { String(data: $0, encoding: .utf8) }
        let magicMatches = mimetypeText?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "application/epub+zip"
        guard archive["META-INF/container.xml"] != nil else {
            throw AdapterError.archiveMissingContainer
        }
        let confidence = magicMatches ? 1.0 : 0.96
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: confidence,
            evidence: [
                ProbeEvidence(
                    id: "\(descriptor.id):container",
                    adapterID: descriptor.id,
                    rule: magicMatches ? "epub-mimetype" : "epub-container",
                    detail: magicMatches ? "application/epub+zip" : "META-INF/container.xml",
                    confidence: confidence
                )
            ],
            reason: "EPUB 容器与 package 入口可识别"
        )
    }

    func verifyRevision(in context: AdapterContext) async throws {
        guard context.snapshot.revisionKind == .contentDigest else { return }
        let bytes = try Data(contentsOf: context.managedURL, options: [.mappedIfSafe])
        guard AdapterUtilities.sha256(bytes) == context.snapshot.revision else {
            throw AdapterError.unsupportedContent("EPUB digest 与 Snapshot 不一致")
        }
    }

    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode] {
        let book = try prepare(context)
        return book.items.prefix(max(1, limit)).enumerated().map { order, item in
            let locator = makeLocator(context, item: item)
            return ContentNode(
                id: locator.stableID,
                title: item.title,
                kind: .spineItem,
                locator: locator,
                depth: 0,
                order: order,
                mediaType: item.mediaType,
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
        let book = try prepare(context)
        guard let item = item(for: locator, in: book) else {
            throw AdapterError.invalidLocator("EPUB spine item 不存在")
        }
        return AdapterUtilities.makeObservation(
            context: context,
            adapterID: descriptor.id,
            locator: locator,
            mediaType: "text/plain; source=application/epub+zip",
            content: item.plainText,
            maxCharacters: maxCharacters,
            contentReference: try relativeDerivedPath(item.sanitizedURL, context: context)
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let book = try prepare(context)
        var hits: [ContentSearchHit] = []
        for item in book.items where hits.count < limit {
            guard let range = item.plainText.range(
                of: needle,
                options: [.caseInsensitive]
            ) else { continue }
            let excerpt = AdapterUtilities.excerpt(from: item.plainText, matching: range)
            let base = makeLocator(context, item: item)
            let locator = Locator(
                sourceID: base.sourceID,
                snapshotID: base.snapshotID,
                adapterID: base.adapterID,
                payload: base.payload,
                structuralPath: base.structuralPath,
                textQuote: TextQuote(prefix: nil, exact: String(item.plainText[range]), suffix: nil),
                fingerprint: AdapterUtilities.sha256(excerpt)
            )
            hits.append(
                ContentSearchHit(
                    id: "\(locator.stableID):search",
                    sourceID: context.source.id,
                    snapshotID: context.snapshot.id,
                    adapterID: descriptor.id,
                    locator: locator,
                    title: item.title,
                    context: excerpt,
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
        let book = try prepare(context)
        guard let item = locator.flatMap({ item(for: $0, in: book) }) ?? book.items.first else {
            throw AdapterError.archiveMalformedPackage("spine 为空")
        }
        let resolvedLocator = locator ?? makeLocator(context, item: item)
        try context.validate(resolvedLocator, adapterID: descriptor.id)
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: .sanitizedWeb,
            locator: resolvedLocator,
            title: item.title,
            mediaType: "application/xhtml+xml",
            content: try String(contentsOf: item.sanitizedURL, encoding: .utf8),
            contentURL: item.sanitizedURL,
            baseURL: book.rootURL,
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
            throw AdapterError.invalidLocator("EPUB Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        let book = try prepare(context)
        let hrefMatch = locator.payload["href"].flatMap { href in
            book.items.first { $0.href == href }
        }
        let quoteMatch = locator.textQuote.flatMap { quote in
            book.items.first { $0.plainText.contains(quote.exact) }
        }
        guard let item = hrefMatch ?? quoteMatch else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新 EPUB 中 spine href 与 quote 均不可用"
            )
        }
        return LocatorResolution(
            state: .relocated,
            requested: locator,
            resolved: makeLocator(context, item: item, quote: locator.textQuote),
            reason: hrefMatch != nil ? "spine href 仍存在" : "精确 quote 已迁移到其他 spine item"
        )
    }

    private func prepare(_ context: AdapterContext) throws -> PreparedEPUB {
        try Task.checkCancellation()
        let parent = context.derivedRootURL
            .appendingPathComponent("epub", isDirectory: true)
        let snapshotRoot = parent.appendingPathComponent(
            context.snapshot.id,
            isDirectory: true
        )
        let finalRoot = try preparedRoot(snapshotRoot: snapshotRoot, context: context)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalRoot.path) {
            return try buildPrepared(root: finalRoot, context: context)
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingRoot = parent.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            try extractValidatedArchive(context.managedURL, to: stagingRoot)
            try Task.checkCancellation()
            _ = try buildPrepared(root: stagingRoot, context: context)
            do {
                if fileManager.fileExists(atPath: finalRoot.path) {
                    try fileManager.removeItem(at: stagingRoot)
                } else {
                    try fileManager.createDirectory(
                        at: finalRoot.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: stagingRoot, to: finalRoot)
                }
            } catch {
                guard fileManager.fileExists(atPath: finalRoot.path) else {
                    throw error
                }
                try? fileManager.removeItem(at: stagingRoot)
            }
            try Task.checkCancellation()
            return try buildPrepared(root: finalRoot, context: context)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    private func preparedRoot(
        snapshotRoot: URL,
        context: AdapterContext
    ) throws -> URL {
        let contentRoot = context.contentRootURL.standardizedFileURL
        let managed = context.managedURL.standardizedFileURL
        guard contentRoot != managed else { return snapshotRoot }
        let rootComponents = contentRoot.pathComponents
        let managedComponents = managed.pathComponents
        guard managedComponents.starts(with: rootComponents) else {
            throw AdapterError.resourceOutsideSource(managed.path)
        }
        let relativePath = managedComponents.dropFirst(rootComponents.count)
            .joined(separator: "/")
        guard !relativePath.isEmpty else { return snapshotRoot }
        return snapshotRoot.appendingPathComponent(
            AdapterUtilities.sha256(relativePath),
            isDirectory: true
        )
    }

    private func extractValidatedArchive(_ archiveURL: URL, to root: URL) throws {
        try SecureArchiveExtractor.extract(
            archiveURL: archiveURL,
            to: root,
            policy: ArchiveExtractionPolicy(
                maximumExpandedBytes: policy.maximumExpandedBytes,
                expansionRatio: policy.expansionRatio
            )
        )
    }

    private func buildPrepared(
        root: URL,
        context: AdapterContext
    ) throws -> PreparedEPUB {
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw AdapterError.archiveMissingContainer
        }
        let rootfile = try EPUBXMLParser.rootfile(in: containerURL)
        let packagePath = try validatedArchivePath(rootfile)
        let packageURL = root.appendingPathComponent(packagePath)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw AdapterError.archiveMissingPackage(packagePath)
        }
        let package = try EPUBXMLParser.package(in: packageURL)
        guard !package.spineIDs.isEmpty else {
            throw AdapterError.archiveMalformedPackage("spine 为空")
        }
        let sanitizedDirectory = root.appendingPathComponent(".onereader-sanitized", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sanitizedDirectory,
            withIntermediateDirectories: true
        )
        var items: [PreparedEPUB.Item] = []
        for (index, id) in package.spineIDs.enumerated() {
            guard let manifest = package.manifest[id] else {
                throw AdapterError.archiveMalformedPackage("spine 引用缺少 manifest item：\(id)")
            }
            let href = try resolvedRelativePath(manifest.href, base: packagePath)
            let originalURL = root.appendingPathComponent(href)
            guard originalURL.standardizedFileURL.pathComponents.starts(
                with: root.standardizedFileURL.pathComponents
            ), FileManager.default.fileExists(atPath: originalURL.path) else {
                throw AdapterError.resourceOutsideSource(href)
            }
            let html = try TextAdapterCore.loadText(originalURL)
            let sanitized = try sanitizedSpine(
                html,
                originalURL: originalURL,
                root: root
            )
            let title = sanitized.title.isEmpty
                ? sanitized.headings.first?.title ?? "章节 \(index + 1)"
                : sanitized.title
            let sanitizedURL = sanitizedDirectory.appendingPathComponent("spine-\(index).html")
            try Data(sanitized.documentHTML.utf8).write(to: sanitizedURL, options: .atomic)
            items.append(
                PreparedEPUB.Item(
                    index: index,
                    id: id,
                    href: href,
                    mediaType: manifest.mediaType,
                    title: title,
                    plainText: sanitized.plainText,
                    originalURL: originalURL,
                    sanitizedURL: sanitizedURL
                )
            )
        }
        return PreparedEPUB(
            title: package.title ?? context.source.displayName,
            rootURL: root,
            items: items
        )
    }

    private func item(for locator: Locator, in book: PreparedEPUB) -> PreparedEPUB.Item? {
        if let index = locator.payload["spineIndex"].flatMap(Int.init),
           book.items.indices.contains(index) {
            return book.items[index]
        }
        if let href = locator.payload["href"] {
            return book.items.first { $0.href == href }
        }
        return nil
    }

    private func sanitizedSpine(
        _ html: String,
        originalURL: URL,
        root: URL
    ) throws -> SanitizedHTML {
        return try HTMLSanitizer.sanitize(
            html,
            baseURL: originalURL,
            managedDocumentURL: originalURL,
            managedResourceRoot: root
        )
    }

    private func makeLocator(
        _ context: AdapterContext,
        item: PreparedEPUB.Item,
        quote: TextQuote? = nil
    ) -> Locator {
        Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: [
                "spineIndex": String(item.index),
                "href": item.href,
            ],
            structuralPath: "spine/\(item.index)/\(item.href)",
            textQuote: quote,
            fingerprint: AdapterUtilities.sha256(item.plainText)
        )
    }

    private func validatedArchivePath(_ rawPath: String) throws -> String {
        try SecureArchiveExtractor.validatedPath(rawPath)
    }

    private func resolvedRelativePath(_ href: String, base packagePath: String) throws -> String {
        let fragmentFree = href.split(separator: "#", maxSplits: 1)
            .first.map(String.init) ?? href
        let decodedHref = fragmentFree.split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? fragmentFree
        let baseDirectory = (packagePath as NSString).deletingLastPathComponent
        let decoded = decodedHref.removingPercentEncoding ?? decodedHref
        guard !decoded.hasPrefix("/"), !decoded.contains("\\") else {
            throw AdapterError.resourceOutsideSource(href)
        }
        var components = baseDirectory.split(separator: "/").map(String.init)
        for component in decoded.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw AdapterError.resourceOutsideSource(href)
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return try validatedArchivePath(components.joined(separator: "/"))
    }

    private func relativeDerivedPath(_ url: URL, context: AdapterContext) throws -> String {
        let root = context.derivedRootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: root) else {
            throw AdapterError.resourceOutsideSource(url.path)
        }
        return components.dropFirst(root.count).joined(separator: "/")
    }

    private func readEntry(_ entry: Entry, from archive: Archive, limit: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else {
            throw AdapterError.archiveExpansionLimit(
                limit: UInt64(limit),
                actual: entry.uncompressedSize
            )
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= limit else {
                throw AdapterError.archiveExpansionLimit(
                    limit: UInt64(limit),
                    actual: UInt64(data.count + chunk.count)
                )
            }
            data.append(chunk)
        }
        return data
    }
}

private struct PreparedEPUB {
    struct Item {
        let index: Int
        let id: String
        let href: String
        let mediaType: String
        let title: String
        let plainText: String
        let originalURL: URL
        let sanitizedURL: URL
    }

    let title: String
    let rootURL: URL
    let items: [Item]
}

private struct EPUBManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
}

private struct EPUBPackage {
    let title: String?
    let manifest: [String: EPUBManifestItem]
    let spineIDs: [String]
}

private enum EPUBXMLParser {
    static func rootfile(in url: URL) throws -> String {
        let delegate = ContainerDelegate()
        try parse(url, delegate: delegate)
        guard let path = delegate.rootfile else {
            throw AdapterError.archiveMissingContainer
        }
        return path
    }

    static func package(in url: URL) throws -> EPUBPackage {
        let delegate = PackageDelegate()
        try parse(url, delegate: delegate)
        return EPUBPackage(
            title: delegate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            manifest: delegate.manifest,
            spineIDs: delegate.spineIDs
        )
    }

    private static func parse(_ url: URL, delegate: XMLParserDelegate) throws {
        guard let parser = XMLParser(contentsOf: url) else {
            throw AdapterError.archiveMalformedPackage(url.lastPathComponent)
        }
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw AdapterError.archiveMalformedPackage(
                parser.parserError?.localizedDescription ?? url.lastPathComponent
            )
        }
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var rootfile: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard localName(qName ?? elementName) == "rootfile", rootfile == nil else { return }
            rootfile = attributeDict["full-path"]
        }
    }

    private final class PackageDelegate: NSObject, XMLParserDelegate {
        var title: String?
        var manifest: [String: EPUBManifestItem] = [:]
        var spineIDs: [String] = []
        private var capturesTitle = false
        private var titleBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch localName(qName ?? elementName) {
            case "title":
                capturesTitle = title == nil
                if capturesTitle { titleBuffer = "" }
            case "item":
                guard let id = attributeDict["id"],
                      let href = attributeDict["href"],
                      let mediaType = attributeDict["media-type"] else { return }
                manifest[id] = EPUBManifestItem(
                    id: id,
                    href: href,
                    mediaType: mediaType,
                    properties: Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
                )
            case "itemref":
                if let idref = attributeDict["idref"] { spineIDs.append(idref) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturesTitle { titleBuffer += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if localName(qName ?? elementName) == "title", capturesTitle {
                title = titleBuffer
                capturesTitle = false
            }
        }
    }

    private static func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }
}
