import Foundation

struct DirectoryAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, ReadingAdapter,
    SearchingAdapter, RenderingAdapter, ResolvingAdapter
{
    static let id = "onereader.directory"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "Directory Structure",
        probeRule: AdapterProbeRule(
            sourceOrigins: [.localDirectory, .githubRepository]
        ),
        capabilities: Set(AdapterCapability.allCases),
        limitations: ["隐藏的 .git 元数据不作为阅读内容展示"]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard TextAdapterCore.isDirectory(context.managedURL) else { return nil }
        let confidence = context.source.originKind == .remoteURL ? 0.98 : 1
        let files = try enumerate(context.managedURL, limit: 2_000)
        let auxiliaries = Set(files.compactMap { entry in
            entry.isDirectory ? nil : Self.childAdapterID(for: entry.relativePath)
        }).sorted()
        let gitRevision = localGitRevision(at: context.managedURL)
        var evidence = [
            ProbeEvidence(
                id: "\(descriptor.id):directory",
                adapterID: descriptor.id,
                rule: "managed-directory",
                detail: "\(files.count) 个可探索条目",
                confidence: confidence
            )
        ]
        if let gitRevision {
            evidence.append(
                ProbeEvidence(
                    id: "\(descriptor.id):git-head",
                    adapterID: descriptor.id,
                    rule: "local-git-head",
                    detail: gitRevision,
                    confidence: 0.98
                )
            )
        }
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: confidence,
            evidence: evidence,
            reason: gitRevision == nil
                ? "托管目录由结构适配器组合子文件适配器"
                : "本地 Git 工作树由目录结构与精确 HEAD 证据组合",
            auxiliaryAdapterIDs: auxiliaries
        )
    }

    func verifyRevision(in context: AdapterContext) async throws {
        guard TextAdapterCore.isDirectory(context.managedURL) else {
            throw AdapterError.unsupportedContent("托管路径不是目录")
        }
        guard context.snapshot.revisionKind == .directoryTreeDigest
                || context.snapshot.revisionKind == .gitCommit else {
            throw AdapterError.unsupportedContent("目录 Snapshot revision kind 不匹配")
        }
    }

    func listContent(
        in context: AdapterContext,
        under locator: Locator?,
        limit: Int
    ) async throws -> [ContentNode] {
        let prefix: String
        let scopedRoot: URL
        if let locator {
            try context.validate(locator, adapterID: descriptor.id)
            prefix = locator.relativePath ?? ""
            scopedRoot = prefix.isEmpty
                ? context.managedURL
                : try childURL(prefix, context: context)
            guard TextAdapterCore.isDirectory(scopedRoot) else {
                throw AdapterError.invalidLocator("Directory locator 不是目录")
            }
        } else {
            prefix = ""
            scopedRoot = context.managedURL
        }
        let entries = try enumerate(scopedRoot, limit: max(1, limit))
        return entries.enumerated().map { order, entry in
            let relativePath = prefix.isEmpty
                ? entry.relativePath
                : "\(prefix)/\(entry.relativePath)"
            let childAdapter = entry.isDirectory
                ? descriptor.id
                : Self.childAdapterID(for: relativePath)
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: childAdapter,
                payload: ["path": relativePath],
                structuralPath: relativePath,
                textQuote: nil,
                fingerprint: nil
            )
            return ContentNode(
                id: locator.stableID,
                title: (relativePath as NSString).lastPathComponent,
                kind: entry.isDirectory ? .directory : .file,
                locator: locator,
                depth: max(0, relativePath.split(separator: "/").count - 1),
                order: order,
                mediaType: Self.mediaType(for: relativePath),
                isReadable: !entry.isDirectory
            )
        }
    }

    func readFragment(
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int
    ) async throws -> Observation {
        try context.validate(locator, adapterID: descriptor.id)
        let path = locator.relativePath ?? ""
        let url = try childURL(path, context: context)
        if TextAdapterCore.isDirectory(url) {
            let children = try enumerate(url, limit: 500)
                .map(\.relativePath)
                .joined(separator: "\n")
            return AdapterUtilities.makeObservation(
                context: context,
                adapterID: descriptor.id,
                locator: locator,
                mediaType: "text/x-directory-listing",
                content: children,
                maxCharacters: maxCharacters
            )
        }
        throw AdapterError.capabilityUnavailable(
            adapterID: descriptor.id,
            capability: .read
        )
    }

    func searchContent(
        in context: AdapterContext,
        query: String,
        limit: Int
    ) async throws -> [ContentSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [ContentSearchHit] = []
        for entry in try enumerate(context.managedURL, limit: 10_000)
        where !entry.isDirectory && hits.count < limit {
            try Task.checkCancellation()
            let childAdapter = Self.childAdapterID(for: entry.relativePath)
            guard childAdapter != QuickLookAdapter.id else { continue }
            let url = try childURL(entry.relativePath, context: context)
            guard let text = try? TextAdapterCore.loadText(url),
                  let range = text.range(of: needle, options: [.caseInsensitive]) else {
                continue
            }
            let excerpt = AdapterUtilities.excerpt(from: text, matching: range)
            let locator = Locator(
                sourceID: context.source.id,
                snapshotID: context.snapshot.id,
                adapterID: childAdapter,
                payload: ["path": entry.relativePath],
                structuralPath: entry.relativePath,
                textQuote: TextQuote(prefix: nil, exact: String(text[range]), suffix: nil),
                fingerprint: AdapterUtilities.sha256(excerpt)
            )
            hits.append(
                ContentSearchHit(
                    id: "\(locator.stableID):search",
                    sourceID: context.source.id,
                    snapshotID: context.snapshot.id,
                    adapterID: childAdapter,
                    locator: locator,
                    title: entry.relativePath,
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
        let resolvedLocator = locator ?? Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: [:],
            structuralPath: "/",
            textQuote: nil,
            fingerprint: context.snapshot.digest
        )
        try context.validate(resolvedLocator, adapterID: descriptor.id)
        let requestedRoot: URL
        if let path = resolvedLocator.relativePath, !path.isEmpty {
            requestedRoot = try childURL(path, context: context)
            guard TextAdapterCore.isDirectory(requestedRoot) else {
                throw AdapterError.invalidLocator("Directory locator 不是目录")
            }
        } else {
            requestedRoot = context.managedURL
        }
        let tree: String = try enumerate(requestedRoot, limit: 1_000)
            .map { entry in
                let indent = String(
                    repeating: "  ",
                    count: max(0, entry.relativePath.split(separator: "/").count - 1)
                )
                return "\(indent)\(entry.isDirectory ? "▸" : "•") \((entry.relativePath as NSString).lastPathComponent)"
            }
            .joined(separator: "\n")
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: .nativeText,
            locator: resolvedLocator,
            title: requestedRoot == context.managedURL
                ? context.source.displayName
                : requestedRoot.lastPathComponent,
            mediaType: "text/x-directory-listing",
            content: tree,
            contentURL: requestedRoot,
            baseURL: requestedRoot,
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
            throw AdapterError.invalidLocator("Directory Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            if let path = locator.relativePath, !path.isEmpty {
                _ = try childURL(path, context: context)
            }
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        let path = locator.relativePath ?? ""
        guard (try? childURL(path, context: context)) != nil else {
            return LocatorResolution(
                state: .orphaned,
                requested: locator,
                resolved: nil,
                reason: "新目录 Snapshot 中路径不存在"
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
            reason: "相对路径在新目录 Snapshot 中仍存在"
        )
    }

    static func childAdapterID(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": PDFAdapter.id
        case "epub": EPUBAdapter.id
        case "md", "markdown", "mdown", "mkd": MarkdownAdapter.id
        case "html", "htm", "xhtml": HTMLAdapter.id
        case let ext where CodeAdapter.extensions.contains(ext): CodeAdapter.id
        case "txt", "text", "log": PlainTextAdapter.id
        default: QuickLookAdapter.id
        }
    }

    private static func mediaType(for path: String) -> String? {
        switch childAdapterID(for: path) {
        case PDFAdapter.id: "application/pdf"
        case EPUBAdapter.id: "application/epub+zip"
        case MarkdownAdapter.id: "text/markdown"
        case HTMLAdapter.id: "text/html"
        case CodeAdapter.id: "text/x-source"
        case PlainTextAdapter.id: "text/plain"
        default: nil
        }
    }

    private func enumerate(_ root: URL, limit: Int) throws -> [DirectoryEntry] {
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw AdapterError.unsupportedContent(root.path)
        }
        var entries: [DirectoryEntry] = []
        let rootComponents = root.standardizedFileURL.pathComponents
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let relativePath = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            if relativePath == ".git" || relativePath.hasPrefix(".git/") {
                if relativePath == ".git" { enumerator.skipDescendants() }
                continue
            }
            if (relativePath as NSString).lastPathComponent == ".DS_Store" { continue }
            if (relativePath as NSString).lastPathComponent.hasPrefix(".onereader-") {
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw LibraryStorageError.symbolicLinkNotAllowed(relativePath)
            }
            guard values.isDirectory == true || values.isRegularFile == true else { continue }
            entries.append(
                DirectoryEntry(
                    relativePath: relativePath,
                    isDirectory: values.isDirectory == true
                )
            )
            if entries.count >= limit { break }
        }
        if let traversalError { throw traversalError }
        return entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
        }
    }

    private func childURL(_ path: String, context: AdapterContext) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw AdapterError.resourceOutsideSource(path)
        }
        let url = context.managedURL.appendingPathComponent(path).standardizedFileURL
        guard url.pathComponents.starts(with: context.managedURL.standardizedFileURL.pathComponents),
              FileManager.default.fileExists(atPath: url.path) else {
            throw AdapterError.resourceOutsideSource(path)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw AdapterError.resourceOutsideSource(path)
        }
        return url
    }

    private func localGitRevision(at root: URL) -> String? {
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let headURL = git.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if !head.hasPrefix("ref: ") { return head }
        let ref = String(head.dropFirst(5))
        return try? String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DirectoryEntry {
    let relativePath: String
    let isDirectory: Bool
}
