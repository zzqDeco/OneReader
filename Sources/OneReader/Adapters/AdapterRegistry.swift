import Foundation

actor AdapterRegistry {
    private let adapters: [String: any ContentAdapter]

    init(adapters: [any ContentAdapter]) throws {
        var table: [String: any ContentAdapter] = [:]
        for adapter in adapters {
            let id = adapter.descriptor.id
            guard table[id] == nil else {
                throw AdapterError.unsupportedContent("重复适配器 ID：\(id)")
            }
            table[id] = adapter
        }
        self.adapters = table
    }

    static func standard() throws -> AdapterRegistry {
        try AdapterRegistry(adapters: [
            PDFAdapter(),
            EPUBAdapter(),
            MarkdownAdapter(),
            HTMLAdapter(),
            WebSnapshotAdapter(),
            CodeAdapter(),
            PlainTextAdapter(),
            DirectoryAdapter(),
            QuickLookAdapter(),
        ])
    }

    func descriptors() -> [AdapterDescriptor] {
        adapters.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    func descriptor(id: String) throws -> AdapterDescriptor {
        guard let descriptor = adapters[id]?.descriptor else {
            throw AdapterError.adapterNotRegistered(id)
        }
        return descriptor
    }

    func deterministicPlan(for context: AdapterContext) async throws -> AdapterPlan {
        var matches: [AdapterProbeMatch] = []
        var probeFailures: [ProbeEvidence] = []
        for id in adapters.keys.sorted() {
            guard let adapter = adapters[id] as? any ProbingAdapter else { continue }
            do {
                if let match = try await adapter.probe(context) {
                    matches.append(match)
                }
            } catch {
                probeFailures.append(
                    ProbeEvidence(
                        id: "\(id):probe-failed",
                        adapterID: id,
                        rule: "probe-failed",
                        detail: Self.probeFailureCategory(error),
                        confidence: 0
                    )
                )
            }
        }
        matches.sort {
            if $0.confidence == $1.confidence { return $0.adapterID < $1.adapterID }
            return $0.confidence > $1.confidence
        }
        guard let primary = matches.first else {
            throw AdapterError.unsupportedContent(context.managedURL.lastPathComponent)
        }

        var routes: [AdapterCapability: String] = [:]
        for capability in AdapterCapability.allCases {
            if let route = matches.first(where: { match in
                adapters[match.adapterID]?.descriptor.capabilities.contains(capability) == true
            }) {
                routes[capability] = route.adapterID
            }
        }

        var auxiliary = primary.auxiliaryAdapterIDs
        auxiliary.append(contentsOf: matches.dropFirst().map(\.adapterID))
        auxiliary = Array(Set(auxiliary.filter { $0 != primary.adapterID })).sorted()
        let evidence = matches.flatMap(\.evidence) + probeFailures
        let seed = [
            context.source.id,
            context.snapshot.id,
            primary.adapterID,
            auxiliary.joined(separator: ","),
        ].joined(separator: "::")

        return AdapterPlan(
            id: "adapter-plan:\(AdapterUtilities.sha256(seed).prefix(24))",
            schemaVersion: AdapterPlan.currentSchemaVersion,
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            primaryAdapterID: primary.adapterID,
            auxiliaryAdapterIDs: auxiliary,
            capabilityRoutes: routes,
            evidence: evidence,
            confidence: primary.confidence,
            reason: probeFailures.isEmpty
                ? primary.reason
                : "\(primary.reason)；\(probeFailures.count) 个格式探测失败，已安全降级",
            isUserOverride: false,
            createdAt: .now
        )
    }

    func verifyRevision(adapterID: String, in context: AdapterContext) async throws {
        let adapter = try capability(
            adapterID: adapterID,
            capability: .revision,
            as: (any RevisionAdapter).self
        )
        try await adapter.verifyRevision(in: context)
    }

    func list(
        adapterID: String,
        in context: AdapterContext,
        under locator: Locator? = nil,
        limit: Int = 500
    ) async throws -> [ContentNode] {
        let adapter = try capability(
            adapterID: adapterID,
            capability: .list,
            as: (any ListingAdapter).self
        )
        return try await adapter.listContent(
            in: context,
            under: locator,
            limit: max(1, limit)
        )
    }

    func read(
        adapterID: String,
        in context: AdapterContext,
        at locator: Locator,
        maxCharacters: Int = 16_384
    ) async throws -> Observation {
        let adapter = try capability(
            adapterID: adapterID,
            capability: .read,
            as: (any ReadingAdapter).self
        )
        return try await adapter.readFragment(
            in: context,
            at: locator,
            maxCharacters: max(1, maxCharacters)
        )
    }

    func search(
        adapterID: String,
        in context: AdapterContext,
        query: String,
        limit: Int = 20
    ) async throws -> [ContentSearchHit] {
        let adapter = try capability(
            adapterID: adapterID,
            capability: .search,
            as: (any SearchingAdapter).self
        )
        return try await adapter.searchContent(
            in: context,
            query: query,
            limit: min(max(1, limit), 20)
        )
    }

    func render(
        adapterID: String,
        in context: AdapterContext,
        at locator: Locator? = nil
    ) async throws -> PresentationDocument {
        let adapter = try capability(
            adapterID: adapterID,
            capability: .render,
            as: (any RenderingAdapter).self
        )
        return try await adapter.presentation(in: context, at: locator)
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        let adapter = try capability(
            adapterID: locator.adapterID,
            capability: .resolve,
            as: (any ResolvingAdapter).self
        )
        return try await adapter.resolve(locator, in: context)
    }

    private func capability<T>(
        adapterID: String,
        capability: AdapterCapability,
        as type: T.Type
    ) throws -> T {
        guard let adapter = adapters[adapterID] else {
            throw AdapterError.adapterNotRegistered(adapterID)
        }
        guard adapter.descriptor.capabilities.contains(capability),
              let typed = adapter as? T else {
            throw AdapterError.capabilityUnavailable(
                adapterID: adapterID,
                capability: capability
            )
        }
        return typed
    }

    private static func probeFailureCategory(_ error: Error) -> String {
        guard let adapterError = error as? AdapterError else {
            return "probe-error"
        }
        switch adapterError {
        case .archiveMissingContainer: return "archive-missing-container"
        case .archiveMissingPackage: return "archive-missing-package"
        case .archiveMalformedPackage: return "archive-malformed-package"
        case .archiveExpansionLimit: return "archive-expansion-limit"
        case .archiveSymlink: return "archive-symlink"
        case .unsafeArchivePath: return "unsafe-archive-path"
        case .unreadableText: return "unreadable-text"
        case .unsafeHTML: return "unsafe-html"
        case .unsupportedContent: return "unsupported-content"
        default: return "adapter-contract-error"
        }
    }
}
