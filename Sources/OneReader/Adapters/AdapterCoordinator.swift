import Foundation
import UniformTypeIdentifiers

struct SearchIndexPolicy: Sendable {
    var maximumNodes = 10_000
    var maximumFragments = 10_000
    var maximumBytes = 128 * 1_024 * 1_024
    var storagePolicy: LibraryStoragePolicy = .production
}

/// One active source, cancellable FIFO waiters, and no staging while queued.
actor SearchIndexGate {
    static let shared = SearchIndexGate()
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard occupied else {
            occupied = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // A cancellation can race with release handing this waiter its slot.
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor SearchIndexWriter {
    let database: LibraryDatabase
    let generationID: String
    let policy: SearchIndexPolicy
    var byteCount = 0
    var fragmentCount = 0

    init(database: LibraryDatabase, generationID: String, policy: SearchIndexPolicy) {
        self.database = database
        self.generationID = generationID
        self.policy = policy
    }

    func checkCapacity(additionalBytes: Int = 0) throws {
        // Reserve headroom for staging, publication, FTS, and WAL in addition to
        // the normal 2 GiB free-space floor. Recheck before every write/commit.
        let reserve = max(Int64(32 * 1_024 * 1_024), Int64(byteCount + additionalBytes) * 8)
        let required = policy.storagePolicy.minimumFreeCapacity + reserve
        let available = try policy.storagePolicy.availableCapacity(at: database.layout.rootURL)
        guard available >= required else {
            throw LibraryStorageError.insufficientFreeSpace(required: required, available: available)
        }
    }

    func stage(_ observation: Observation, title: String?) throws {
        try Task.checkCancellation()
        guard !observation.truncated else {
            throw AdapterError.unsupportedContent("内容被截断，未发布不完整的全文索引")
        }
        let size = observation.content.utf8.count
            + (try JSONEncoder().encode(observation.locator).count)
            + (title?.utf8.count ?? 0) + 1_024
        guard fragmentCount < policy.maximumFragments,
              size <= policy.maximumBytes - byteCount else {
            throw AdapterError.unsupportedContent("全文索引超过容量预算，基础阅读仍可使用")
        }
        try checkCapacity(additionalBytes: size)
        try database.stageObservation(observation, title: title, generationID: generationID)
        byteCount += size
        fragmentCount += 1
    }
}

actor AdapterCoordinator {
    let database: LibraryDatabase
    let registry: AdapterRegistry
    let indexingPolicy: SearchIndexPolicy

    init(
        database: LibraryDatabase,
        registry: AdapterRegistry,
        indexingPolicy: SearchIndexPolicy = .init()
    ) {
        self.database = database
        self.registry = registry
        self.indexingPolicy = indexingPolicy
    }

    static func standard(database: LibraryDatabase) throws -> AdapterCoordinator {
        AdapterCoordinator(database: database, registry: try .standard())
    }

    func prepare(sourceID: String, snapshotID: String) async throws -> AdapterPlan {
        let context = try context(sourceID: sourceID, snapshotID: snapshotID)
        let plan = try await registry.deterministicPlan(for: context)
        if plan.capabilityRoutes[.revision] != nil {
            try await registry.verifyRevision(
                adapterID: plan.capabilityRoutes[.revision] ?? plan.primaryAdapterID,
                in: context
            )
        }
        try database.saveAdapterPlan(plan)
        return plan
    }

    func deterministicPlan(sourceID: String, snapshotID: String) async throws -> AdapterPlan {
        try await registry.deterministicPlan(
            for: context(sourceID: sourceID, snapshotID: snapshotID)
        )
    }

    func prepareAndIndex(sourceID: String, snapshotID: String) async throws -> AdapterPlan {
        let plan = try await prepare(sourceID: sourceID, snapshotID: snapshotID)
        try await index(plan: plan)
        return plan
    }

    func list(
        plan: AdapterPlan,
        under locator: Locator? = nil,
        limit: Int = 500
    ) async throws -> [ContentNode] {
        let base = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
        let adapterID = locator?.adapterID
            ?? plan.capabilityRoutes[.list]
            ?? plan.primaryAdapterID
        try await requireSelected(
            adapterID: adapterID,
            capability: .list,
            plan: plan
        )
        let adapted = try adaptedContext(base, for: locator, adapterID: adapterID)
        return try await registry.list(
            adapterID: adapterID,
            in: adapted,
            under: locator,
            limit: limit
        )
    }

    func read(
        plan: AdapterPlan,
        locator: Locator,
        maxCharacters: Int = 16_384,
        persistObservation: Bool = true
    ) async throws -> Observation {
        guard locator.sourceID == plan.sourceID,
              locator.snapshotID == plan.snapshotID else {
            throw AdapterError.invalidLocator("Locator 不属于 AdapterPlan 的 Snapshot")
        }
        try await requireSelected(
            adapterID: locator.adapterID,
            capability: .read,
            plan: plan
        )
        let base = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
        let adapted = try adaptedContext(base, for: locator, adapterID: locator.adapterID)
        let observation = try await registry.read(
            adapterID: locator.adapterID,
            in: adapted,
            at: locator,
            maxCharacters: maxCharacters
        )
        if persistObservation {
            try database.saveObservation(observation, title: locator.relativePath)
        }
        return observation
    }

    func search(
        plan: AdapterPlan,
        query: String,
        limit: Int = 20,
        preferIndex: Bool = true
    ) async throws -> [ContentSearchHit] {
        if preferIndex {
            let indexed = try database.searchObservations(
                query: query,
                snapshotID: plan.snapshotID,
                planID: plan.id,
                limit: limit
            )
            if !indexed.isEmpty { return indexed }
        }
        let context = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
        let adapterID = plan.capabilityRoutes[.search] ?? plan.primaryAdapterID
        return try await registry.search(
            adapterID: adapterID,
            in: context,
            query: query,
            limit: limit
        )
    }

    func render(
        plan: AdapterPlan,
        locator: Locator? = nil
    ) async throws -> PresentationDocument {
        let base = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
        let adapterID = locator?.adapterID
            ?? plan.capabilityRoutes[.render]
            ?? plan.primaryAdapterID
        try await requireSelected(
            adapterID: adapterID,
            capability: .render,
            plan: plan
        )
        let adapted = try adaptedContext(base, for: locator, adapterID: adapterID)
        return try await registry.render(
            adapterID: adapterID,
            in: adapted,
            at: locator
        )
    }

    func resolve(
        _ locator: Locator,
        against snapshotID: String
    ) async throws -> LocatorResolution {
        let base = try context(sourceID: locator.sourceID, snapshotID: snapshotID)
        let adapted = try adaptedContext(base, for: locator, adapterID: locator.adapterID)
        return try await registry.resolve(locator, in: adapted)
    }

    func resolveStaged(
        _ locator: Locator,
        source: Source,
        snapshot: SourceSnapshot,
        managedURL: URL
    ) async throws -> LocatorResolution {
        guard locator.sourceID == source.id,
              snapshot.sourceID == source.id,
              managedURL.isFileURL,
              FileManager.default.fileExists(atPath: managedURL.path) else {
            throw AdapterError.invalidLocator("刷新候选与 Locator 的来源身份不一致")
        }
        let base = AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: managedURL,
            contentRootURL: managedURL,
            derivedRootURL: database.layout.derivedURL,
            declaredMediaType: Self.mediaType(for: source.displayName)
        )
        let adapted = try adaptedContext(base, for: locator, adapterID: locator.adapterID)
        return try await registry.resolve(locator, in: adapted)
    }

    func index(plan: AdapterPlan) async throws {
        try Task.checkCancellation()
        guard plan.capabilityRoutes[.list] != nil,
              plan.capabilityRoutes[.read] != nil else {
            return
        }
        // Actor reentrancy alone does not bound concurrent sources. The process-wide
        // FIFO gate covers bootstrap, imports, refreshes, and separate coordinators.
        try await SearchIndexGate.shared.acquire()
        do {
            try await buildIndex(plan: plan)
            await SearchIndexGate.shared.release()
        } catch {
            await SearchIndexGate.shared.release()
            throw error
        }
    }

    private func buildIndex(plan: AdapterPlan) async throws {
        try Task.checkCancellation()
        let generationID = try database.beginObservationIndex(
            snapshotID: plan.snapshotID,
            planID: plan.id
        )
        let writer = SearchIndexWriter(
            database: database, generationID: generationID, policy: indexingPolicy
        )
        do {
            try await writer.checkCapacity()
            let base = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
            let readerID = plan.capabilityRoutes[.read] ?? plan.primaryAdapterID
            let rootIndexed: Bool
            if plan.primaryAdapterID != DirectoryAdapter.id {
                try await requireSelected(adapterID: readerID, capability: .read, plan: plan)
                rootIndexed = try await indexContent(
                    adapterID: readerID,
                    context: adaptedContext(base, for: nil, adapterID: readerID),
                    writer: writer
                )
            } else {
                rootIndexed = false
            }
            let nodes = rootIndexed ? [] : try await indexableNodes(
                plan: plan, limit: indexingPolicy.maximumNodes
            )
            for node in nodes where node.isReadable {
                try Task.checkCancellation()
                // Quick Look explicitly has no text/search capability.
                if node.locator.adapterID == QuickLookAdapter.id { continue }
                try await requireSelected(
                    adapterID: node.locator.adapterID, capability: .read, plan: plan
                )
                if try await indexContent(
                    adapterID: node.locator.adapterID,
                    context: adaptedContext(
                        base, for: node.locator, adapterID: node.locator.adapterID
                    ),
                    writer: writer
                ) { continue }
                let observation = try await read(
                    plan: plan,
                    locator: node.locator,
                    maxCharacters: 1_000_000,
                    persistObservation: false
                )
                try await writer.stage(
                    observation,
                    title: node.locator.relativePath ?? node.title
                )
            }
            try Task.checkCancellation()
            try await writer.checkCapacity()
            try database.completeObservationIndex(
                snapshotID: plan.snapshotID,
                planID: plan.id,
                generationID: generationID
            )
        } catch is CancellationError {
            try? database.failObservationIndex(
                snapshotID: plan.snapshotID,
                planID: plan.id,
                generationID: generationID,
                category: "cancelled"
            )
            throw CancellationError()
        } catch {
            try? database.failObservationIndex(
                snapshotID: plan.snapshotID,
                planID: plan.id,
                generationID: generationID,
                category: "index-failed"
            )
            throw error
        }
    }

    private func indexContent(
        adapterID: String,
        context: AdapterContext,
        writer: SearchIndexWriter
    ) async throws -> Bool {
        try await registry.index(adapterID: adapterID, in: context) { observation in
            try Task.checkCancellation()
            try await writer.stage(
                observation,
                title: observation.locator.relativePath ?? context.source.displayName
            )
        }
    }

    private func indexableNodes(
        plan: AdapterPlan,
        limit: Int
    ) async throws -> [ContentNode] {
        let rootNodes = try await list(plan: plan, limit: limit + 1)
        guard rootNodes.count <= limit else {
            throw AdapterError.unsupportedContent("全文索引超过 \(limit) 个条目上限，未发布不完整索引")
        }
        guard plan.primaryAdapterID == DirectoryAdapter.id else { return rootNodes }
        let base = try context(sourceID: plan.sourceID, snapshotID: plan.snapshotID)
        var expanded: [ContentNode] = []
        expanded.reserveCapacity(rootNodes.count)
        for rootNode in rootNodes {
            try Task.checkCancellation()
            guard rootNode.isReadable else { continue }
            guard expanded.count < limit else {
                throw AdapterError.unsupportedContent("全文索引超过 \(limit) 个内容节点上限")
            }
            let adapterID = rootNode.locator.adapterID
            guard adapterID == PDFAdapter.id || adapterID == EPUBAdapter.id,
                  let path = rootNode.locator.payload["path"] else {
                expanded.append(rootNode)
                continue
            }
            let childContext = try adaptedContext(
                base,
                for: rootNode.locator,
                adapterID: adapterID
            )
            let remaining = max(1, limit - expanded.count)
            let childNodes = try await registry.list(
                adapterID: adapterID,
                in: childContext,
                under: nil,
                limit: remaining + 1
            )
            guard childNodes.count <= remaining else {
                throw AdapterError.unsupportedContent("全文索引超过 \(limit) 个内容节点上限")
            }
            expanded.append(contentsOf: childNodes.map { child in
                let locator = Self.rebinding(child.locator, toDirectoryPath: path)
                return ContentNode(
                    id: locator.stableID,
                    title: "\(rootNode.title) · \(child.title)",
                    kind: child.kind,
                    locator: locator,
                    depth: rootNode.depth + child.depth + 1,
                    order: expanded.count + child.order,
                    mediaType: child.mediaType,
                    isReadable: child.isReadable
                )
            })
        }
        return expanded
    }

    private static func rebinding(
        _ locator: Locator,
        toDirectoryPath path: String
    ) -> Locator {
        var payload = locator.payload
        payload["path"] = path
        let childPath = locator.structuralPath ?? locator.conciseDescription
        return Locator(
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID,
            adapterID: locator.adapterID,
            schemaVersion: locator.schemaVersion,
            payload: payload,
            structuralPath: "\(path)::\(childPath)",
            textQuote: locator.textQuote,
            fingerprint: locator.fingerprint
        )
    }

    private func context(sourceID: String, snapshotID: String) throws -> AdapterContext {
        guard let source = try database.fetchSources()
            .first(where: { $0.id == sourceID }) else {
            throw LibraryStorageError.missingSource(sourceID)
        }
        guard let snapshot = try database.fetchSnapshots(sourceID: sourceID)
            .first(where: { $0.id == snapshotID }) else {
            throw AdapterError.unsupportedContent("Snapshot 不存在：\(snapshotID)")
        }
        guard let relativePath = snapshot.managedRelativePath else {
            throw AdapterError.unsupportedContent("Snapshot 没有托管内容路径")
        }
        let managedURL = try database.layout.url(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: managedURL.path) else {
            throw LibraryStorageError.sourceUnavailable(managedURL.path)
        }
        return AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: managedURL,
            contentRootURL: managedURL,
            derivedRootURL: database.layout.derivedURL,
            declaredMediaType: Self.mediaType(for: source.displayName)
        )
    }

    private func requireSelected(
        adapterID: String,
        capability: AdapterCapability,
        plan: AdapterPlan
    ) async throws {
        let selected = Set(plan.auxiliaryAdapterIDs).union([plan.primaryAdapterID])
        guard selected.contains(adapterID) else {
            throw AdapterError.invalidLocator("Locator Adapter 不属于当前 AdapterPlan")
        }
        let descriptor = try await registry.descriptor(id: adapterID)
        guard descriptor.capabilities.contains(capability) else {
            throw AdapterError.capabilityUnavailable(
                adapterID: adapterID,
                capability: capability
            )
        }
    }

    private func adaptedContext(
        _ base: AdapterContext,
        for locator: Locator?,
        adapterID: String
    ) throws -> AdapterContext {
        guard TextAdapterCore.isDirectory(base.managedURL),
              adapterID != DirectoryAdapter.id,
              adapterID != WebSnapshotAdapter.id,
              let path = locator?.relativePath else {
            return base
        }
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw AdapterError.resourceOutsideSource(path)
        }
        let childURL = base.managedURL.appendingPathComponent(path).standardizedFileURL
        guard childURL.pathComponents.starts(with: base.managedURL.standardizedFileURL.pathComponents),
              FileManager.default.fileExists(atPath: childURL.path) else {
            throw AdapterError.resourceOutsideSource(path)
        }
        let values = try childURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw AdapterError.resourceOutsideSource(path)
        }
        return AdapterContext(
            source: base.source,
            snapshot: base.snapshot,
            managedURL: childURL,
            contentRootURL: base.managedURL,
            derivedRootURL: base.derivedRootURL,
            declaredMediaType: Self.mediaType(for: path)
        )
    }

    private static func mediaType(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }
}
