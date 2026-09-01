import Foundation

enum AgentDomainMutation: Sendable {
    case adapterPlan(AdapterPlan)
    case readingGraph(ReadingGraph, expectedSnapshots: [String: String])
    case readingPlan(ReadingPlanDraft, expectedSnapshots: [String: String])
}

enum AgentCommitDisposition: Sendable {
    case committed(kind: String, identifier: String, mutation: AgentDomainMutation)
    case acceptedWithoutCommit(kind: String)
    case waitingForUser(reason: String, candidate: AgentStructuredOutput)
}

actor AgentOutputValidator {
    private let database: LibraryDatabase
    private let registry: AdapterRegistry
    private let coordinator: AdapterCoordinator

    init(database: LibraryDatabase, registry: AdapterRegistry) {
        self.database = database
        self.registry = registry
        coordinator = AdapterCoordinator(database: database, registry: registry)
    }

    func validate(
        _ output: AgentStructuredOutput,
        request: AgentRunRequest
    ) async throws -> AgentCommitDisposition {
        guard try database.containsSpace(request.spaceID) else {
            throw ReadingAgentError.validationRejected("space-not-found")
        }
        switch output {
        case .adapterPlan(let plan):
            return try await validateAdapterPlan(plan, request: request)
        case .graphPatch(let patch):
            return try await validateGraphPatch(patch, request: request)
        case .readingPlan(let draft):
            return try validateReadingPlan(draft, request: request)
        case .evidenceAnswer(let answer):
            return try await validateEvidenceAnswer(answer, request: request)
        case .scoutingSummary(let summary):
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  summary.count <= 32_768 else {
                throw ReadingAgentError.validationRejected("invalid-scout-summary")
            }
            return .acceptedWithoutCommit(kind: "scoutingSummary")
        }
    }

    func confirmAdapterPlan(
        _ plan: AdapterPlan,
        request: AgentRunRequest
    ) async throws -> AdapterPlan {
        guard !plan.isUserOverride else {
            throw ReadingAgentError.validationRejected("adapter-plan-contract")
        }
        let confirmed = AdapterPlan(
            id: plan.id,
            schemaVersion: plan.schemaVersion,
            sourceID: plan.sourceID,
            snapshotID: plan.snapshotID,
            primaryAdapterID: plan.primaryAdapterID,
            auxiliaryAdapterIDs: plan.auxiliaryAdapterIDs,
            capabilityRoutes: plan.capabilityRoutes,
            evidence: plan.evidence,
            confidence: plan.confidence,
            reason: plan.reason,
            isUserOverride: true,
            createdAt: .now
        )
        let disposition = try await validateAdapterPlan(
            confirmed,
            request: request,
            acceptsUserOverride: true
        )
        guard case .committed(_, _, .adapterPlan(let hostPlan)) = disposition else {
            throw ReadingAgentError.validationRejected("adapter-confirmation-failed")
        }
        return hostPlan
    }

    private func validateAdapterPlan(
        _ plan: AdapterPlan,
        request: AgentRunRequest,
        acceptsUserOverride: Bool = false
    ) async throws -> AgentCommitDisposition {
        guard request.task == .routeAdapters,
              plan.schemaVersion == AdapterPlan.currentSchemaVersion,
              (0...1).contains(plan.confidence),
              !plan.reason.isEmpty,
              !plan.evidence.isEmpty,
              plan.isUserOverride == acceptsUserOverride else {
            throw ReadingAgentError.validationRejected("adapter-plan-contract")
        }
        let manifest = try boundManifest(for: request)
        guard manifest[plan.sourceID] == plan.snapshotID else {
            throw ReadingAgentError.validationRejected("snapshot-not-current")
        }
        if request.targetSourceID != nil || request.targetSnapshotID != nil {
            guard request.targetSourceID == plan.sourceID,
                  request.targetSnapshotID == plan.snapshotID else {
                throw ReadingAgentError.validationRejected("adapter-route-target-mismatch")
            }
        }
        let descriptors = await registry.descriptors()
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        guard let primary = byID[plan.primaryAdapterID] else {
            throw ReadingAgentError.validationRejected("primary-adapter-not-registered")
        }
        let auxiliary = Set(plan.auxiliaryAdapterIDs)
        guard auxiliary.count == plan.auxiliaryAdapterIDs.count,
              !auxiliary.contains(primary.id),
              auxiliary.allSatisfy({ byID[$0] != nil }) else {
            throw ReadingAgentError.validationRejected("auxiliary-adapter-invalid")
        }
        let allowedAdapters = auxiliary.union([primary.id])
        for (capability, adapterID) in plan.capabilityRoutes {
            guard allowedAdapters.contains(adapterID),
                  byID[adapterID]?.capabilities.contains(capability) == true else {
                throw ReadingAgentError.validationRejected("capability-route-invalid")
            }
        }
        guard plan.evidence.allSatisfy({ evidence in
            allowedAdapters.contains(evidence.adapterID)
                && (0...1).contains(evidence.confidence)
        }) else {
            throw ReadingAgentError.validationRejected("probe-evidence-invalid")
        }
        guard try database.fetchAdapterPlan(snapshotID: plan.snapshotID) != nil else {
            throw ReadingAgentError.validationRejected("deterministic-plan-missing")
        }
        let reprobed = try await coordinator.deterministicPlan(
            sourceID: plan.sourceID,
            snapshotID: plan.snapshotID
        )
        let hostSelected = Set(reprobed.auxiliaryAdapterIDs).union([reprobed.primaryAdapterID])
        guard allowedAdapters.isSubset(of: hostSelected),
              (plan.primaryAdapterID == reprobed.primaryAdapterID
                || reprobed.evidence.contains(where: {
                    $0.adapterID == plan.primaryAdapterID && $0.confidence > 0
                })),
              plan.reason.count <= 4_096 else {
            throw ReadingAgentError.validationRejected("adapter-selection-not-probed")
        }
        guard Set(plan.evidence.map(\.id)).count == plan.evidence.count,
              Set(reprobed.evidence.map(\.id)).count == reprobed.evidence.count else {
            throw ReadingAgentError.validationRejected("probe-evidence-invalid")
        }
        let freshEvidence = Dictionary(
            uniqueKeysWithValues: reprobed.evidence.map { ($0.id, $0) }
        )
        guard plan.evidence.allSatisfy({ freshEvidence[$0.id] == $0 }) else {
            throw ReadingAgentError.validationRejected("probe-evidence-not-grounded")
        }

        let confidenceByAdapter = Dictionary(grouping: reprobed.evidence, by: \.adapterID)
            .mapValues { evidence in evidence.map(\.confidence).max() ?? 0 }
        guard let hostConfidence = confidenceByAdapter[plan.primaryAdapterID],
              hostConfidence > 0 else {
            throw ReadingAgentError.validationRejected("primary-adapter-not-probed")
        }
        var hostRoutes: [AdapterCapability: String] = [:]
        for capability in AdapterCapability.allCases {
            let candidates = allowedAdapters.filter {
                byID[$0]?.capabilities.contains(capability) == true
            }.sorted {
                let left = confidenceByAdapter[$0] ?? 0
                let right = confidenceByAdapter[$1] ?? 0
                return left == right ? $0 < $1 : left > right
            }
            if let selected = candidates.first {
                hostRoutes[capability] = selected
            }
        }
        guard hostRoutes[.render] != nil else {
            throw ReadingAgentError.validationRejected("capability-route-incomplete")
        }
        let hostEvidence = reprobed.evidence.filter {
            allowedAdapters.contains($0.adapterID)
        }
        let hostPlan = AdapterPlan(
            id: "agent-adapter-plan:\(UUID().uuidString.lowercased())",
            schemaVersion: plan.schemaVersion,
            sourceID: plan.sourceID,
            snapshotID: plan.snapshotID,
            primaryAdapterID: plan.primaryAdapterID,
            auxiliaryAdapterIDs: plan.auxiliaryAdapterIDs,
            capabilityRoutes: hostRoutes,
            evidence: hostEvidence,
            confidence: hostConfidence,
            reason: plan.reason,
            isUserOverride: acceptsUserOverride,
            createdAt: .now
        )
        let baselineCapabilities = Set(reprobed.capabilityRoutes.keys)
        let preservesBaseline = baselineCapabilities.isSubset(of: Set(hostRoutes.keys))
        if !acceptsUserOverride,
           (plan.primaryAdapterID != reprobed.primaryAdapterID
                || hostConfidence < 0.85
                || !preservesBaseline) {
            return .waitingForUser(
                reason: "adapter-combination-requires-confirmation",
                candidate: .adapterPlan(hostPlan)
            )
        }
        return .committed(
            kind: "adapterPlan",
            identifier: hostPlan.id,
            mutation: .adapterPlan(hostPlan)
        )
    }

    private func validateGraphPatch(
        _ patch: GraphPatch,
        request: AgentRunRequest
    ) async throws -> AgentCommitDisposition {
        guard request.task == .materializeGraph,
              patch.schemaVersion == GraphPatch.currentSchemaVersion,
              !patch.graphID.isEmpty,
              try database.readingGraph(id: patch.graphID) == nil else {
            throw ReadingAgentError.validationRejected("graph-patch-contract")
        }
        let manifest = try boundManifest(for: request)
        let expected = Set(manifest.values)
        guard patch.snapshotIDs == expected else {
            throw ReadingAgentError.validationRejected("snapshot-set-changed")
        }

        let base: ReadingGraph?
        if let baseVersion = patch.baseGraphVersion {
            guard let latest = try database.latestReadingGraph(spaceID: request.spaceID),
                  latest.version == baseVersion else {
                throw ReadingAgentError.validationRejected("base-graph-version-mismatch")
            }
            base = latest
        } else {
            base = nil
        }

        let descriptors = await registry.descriptors()
        let descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        let sourceIDs = Set(manifest.keys)
        var upserts = [String: ReadingUnit]()
        for unit in patch.upsertUnits {
            guard upserts[unit.id] == nil,
                  !unit.id.isEmpty,
                  !unit.title.isEmpty,
                  !unit.fragments.isEmpty,
                  unit.estimatedMinutes > 0,
                  (0...1).contains(unit.importance),
                  (0...1).contains(unit.confidence) else {
                throw ReadingAgentError.validationRejected("reading-unit-contract")
            }
            for fragment in unit.fragments {
                try validateFragment(
                    fragment,
                    expectedSnapshots: expected,
                    sourceIDs: sourceIDs,
                    descriptors: descriptorByID
                )
            }
            upserts[unit.id] = unit
        }
        guard patch.removeUnitIDs.isDisjoint(with: Set(upserts.keys)) else {
            throw ReadingAgentError.validationRejected("unit-upsert-remove-conflict")
        }

        var unitsByID = Dictionary(uniqueKeysWithValues: (base?.units ?? []).map { ($0.id, $0) })
        patch.removeUnitIDs.forEach { unitsByID[$0] = nil }
        upserts.forEach { unitsByID[$0.key] = $0.value }
        let finalIDs = Set(unitsByID.keys)
        for unit in unitsByID.values {
            guard !unit.fragments.isEmpty else {
                throw ReadingAgentError.validationRejected("reading-unit-contract")
            }
            for fragment in unit.fragments {
                try validateFragment(
                    fragment,
                    expectedSnapshots: expected,
                    sourceIDs: sourceIDs,
                    descriptors: descriptorByID
                )
            }
            guard unit.relations.allSatisfy({ relation in
                finalIDs.contains(relation.targetUnitID)
                    && (0...1).contains(relation.confidence)
                    && relation.weight.isFinite
            }) else {
                throw ReadingAgentError.validationRejected("unit-relation-invalid")
            }
        }

        let snapshots = try database.fetchSnapshots().filter { expected.contains($0.id) }
        guard Set(snapshots.map(\.id)) == expected else {
            throw ReadingAgentError.validationRejected("snapshot-missing")
        }
        let units = unitsByID.values.sorted {
            if $0.sourceOrder == $1.sourceOrder { return $0.id < $1.id }
            return $0.sourceOrder < $1.sourceOrder
        }
        let version = try graphVersion(snapshotIDs: expected, units: units)
        let spaceTitle = try database.fetchSpaces()
            .first(where: { $0.id == request.spaceID })?.title ?? "Reading Space"
        let graph = ReadingGraph(
            id: "reading-graph:\(UUID().uuidString.lowercased())",
            version: version,
            title: spaceTitle,
            sourceSnapshots: snapshots.sorted { $0.sourceID < $1.sourceID },
            units: units,
            mapperID: "onereader.reading-agent",
            mapperVersion: "1",
            generatedAt: .now
        )
        let snapshotBySource = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceID, $0.id) })
        return .committed(
            kind: "readingGraph",
            identifier: graph.id,
            mutation: .readingGraph(graph, expectedSnapshots: snapshotBySource)
        )
    }

    private func validateReadingPlan(
        _ draft: ReadingPlanDraft,
        request: AgentRunRequest
    ) throws -> AgentCommitDisposition {
        guard request.task == .projectRoute,
              draft.schemaVersion == ReadingPlanDraft.currentSchemaVersion,
              !draft.id.isEmpty,
              !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.orderedUnitIDs.isEmpty,
              Set(draft.orderedUnitIDs).count == draft.orderedUnitIDs.count,
              let graph = try database.readingGraph(id: draft.graphID),
              graph.version == draft.graphVersion else {
            throw ReadingAgentError.validationRejected("reading-plan-contract")
        }
        let graphUnitIDs = Set(graph.units.map(\.id))
        guard draft.orderedUnitIDs.allSatisfy(graphUnitIDs.contains),
              Set(draft.reasons.keys).isSubset(of: Set(draft.orderedUnitIDs)) else {
            throw ReadingAgentError.validationRejected("reading-plan-unit-invalid")
        }
        let manifest = try boundManifest(for: request)
        let expected = Set(manifest.values)
        guard Set(graph.sourceSnapshots.map(\.id)) == expected else {
            throw ReadingAgentError.validationRejected("snapshot-set-changed")
        }
        let hostDraft = ReadingPlanDraft(
            id: "reading-plan:\(UUID().uuidString.lowercased())",
            schemaVersion: draft.schemaVersion,
            graphID: draft.graphID,
            graphVersion: draft.graphVersion,
            goal: draft.goal,
            orderedUnitIDs: draft.orderedUnitIDs,
            reasons: draft.reasons,
            createdAt: .now
        )
        return .committed(
            kind: "readingPlan",
            identifier: hostDraft.id,
            mutation: .readingPlan(hostDraft, expectedSnapshots: manifest)
        )
    }

    private func validateEvidenceAnswer(
        _ answer: EvidenceAnswer,
        request: AgentRunRequest
    ) async throws -> AgentCommitDisposition {
        guard request.task == .answerWithEvidence,
              answer.schemaVersion == EvidenceAnswer.currentSchemaVersion,
              !answer.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.citations.isEmpty,
              Set(answer.citations.map(\.id)).count == answer.citations.count else {
            throw ReadingAgentError.validationRejected("evidence-answer-contract")
        }
        let current = try boundManifest(for: request)
        let descriptors = await registry.descriptors()
        let descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        for citation in answer.citations {
            guard citation.sourceID == citation.locator.sourceID,
                  citation.snapshotID == citation.locator.snapshotID,
                  current[citation.sourceID] == citation.snapshotID,
                  citation.locator.schemaVersion == Locator.currentSchemaVersion,
                  descriptorByID[citation.locator.adapterID]?.capabilities.contains(.read) == true,
                  !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try database.hasObservation(for: citation.locator, containing: citation.quote) else {
                throw ReadingAgentError.validationRejected("citation-not-grounded")
            }
        }
        return .acceptedWithoutCommit(kind: "evidenceAnswer")
    }

    private func validateFragment(
        _ fragment: SourceFragment,
        expectedSnapshots: Set<String>,
        sourceIDs: Set<String>,
        descriptors: [String: AdapterDescriptor]
    ) throws {
        let locator = fragment.locator
        guard fragment.sourceID == locator.sourceID,
              sourceIDs.contains(fragment.sourceID),
              expectedSnapshots.contains(locator.snapshotID),
              locator.schemaVersion == Locator.currentSchemaVersion,
              descriptors[locator.adapterID]?.capabilities.contains(.read) == true,
              try database.hasObservation(for: locator) else {
            throw ReadingAgentError.validationRejected("fragment-not-grounded")
        }
    }

    private func currentSnapshots(spaceID: String) throws -> [String: String] {
        let sourceIDs = Set(try database.sourceIDs(in: spaceID))
        return Dictionary(uniqueKeysWithValues: try database.fetchSources()
            .filter { sourceIDs.contains($0.id) }
            .compactMap { source in
                source.latestSnapshotID.map { (source.id, $0) }
            })
    }

    private func boundManifest(for request: AgentRunRequest) throws -> [String: String] {
        let current = try currentSnapshots(spaceID: request.spaceID)
        let manifest = request.snapshotManifest.isEmpty ? current : request.snapshotManifest
        guard !manifest.isEmpty,
              manifest == current,
              request.expectedSnapshotIDs.isEmpty
                || request.expectedSnapshotIDs == Set(manifest.values) else {
            throw ReadingAgentError.validationRejected("snapshot-set-changed")
        }
        return manifest
    }

    private func graphVersion(snapshotIDs: Set<String>, units: [ReadingUnit]) throws -> String {
        struct VersionInput: Codable {
            let snapshots: [String]
            let units: [ReadingUnit]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(VersionInput(
            snapshots: snapshotIDs.sorted(),
            units: units
        ))
        return AdapterUtilities.sha256(data)
    }
}
