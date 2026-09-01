import Foundation
import UniformTypeIdentifiers

actor AdapterCoordinator {
    let database: LibraryDatabase
    let registry: AdapterRegistry

    init(database: LibraryDatabase, registry: AdapterRegistry) {
        self.database = database
        self.registry = registry
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
        maxCharacters: Int = 16_384
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
        try database.saveObservation(observation, title: locator.relativePath)
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

    func index(plan: AdapterPlan) async throws {
        try Task.checkCancellation()
        guard plan.capabilityRoutes[.list] != nil,
              plan.capabilityRoutes[.read] != nil else {
            return
        }
        let nodes = try await list(plan: plan, limit: 2_000)
        for node in nodes where node.isReadable {
            try Task.checkCancellation()
            do {
                _ = try await read(
                    plan: plan,
                    locator: node.locator,
                    maxCharacters: 1_000_000
                )
            } catch let error as AdapterError {
                if case .capabilityUnavailable = error { continue }
                throw error
            }
        }
        try Task.checkCancellation()
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
