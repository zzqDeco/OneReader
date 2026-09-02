import Foundation
import XCTest
@testable import OneReader

final class AgentOutputValidatorTests: XCTestCase {
    func testGraphPatchRejectsUnitWithoutRealEvidence() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let unit = ReadingUnit(
            id: "unit-forged",
            title: "Forged",
            summary: "No evidence",
            fragments: [],
            relations: [],
            estimatedMinutes: 5,
            importance: 0.5,
            confidence: 0.5,
            sourceOrder: 0,
            preferredPresentation: .markdown
        )
        let patch = GraphPatch(
            id: "patch-forged",
            schemaVersion: GraphPatch.currentSchemaVersion,
            graphID: "graph-forged",
            baseGraphVersion: nil,
            snapshotIDs: [fixture.imported.snapshot.id],
            upsertUnits: [unit],
            removeUnitIDs: [],
            generatedAt: .now
        )

        do {
            _ = try await fixture.validator.validate(
                .graphPatch(patch),
                request: AgentRunRequest(
                    spaceID: fixture.imported.space.id,
                    task: .materializeGraph,
                    expectedSnapshotIDs: [fixture.imported.snapshot.id]
                )
            )
            XCTFail("Expected evidence rejection")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .validationRejected("reading-unit-contract"))
        }
    }

    func testGroundedGraphPatchProducesHostOwnedMutationAndStaleLocatorIsRejected() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let locator = try XCTUnwrap(fixture.locator)
        let unit = groundedUnit(locator: locator, sourceID: fixture.imported.source.id)
        let patch = GraphPatch(
            id: "patch-grounded",
            schemaVersion: GraphPatch.currentSchemaVersion,
            graphID: "graph-grounded",
            baseGraphVersion: nil,
            snapshotIDs: [fixture.imported.snapshot.id],
            upsertUnits: [unit],
            removeUnitIDs: [],
            generatedAt: .now
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .materializeGraph,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        )

        let disposition = try await fixture.validator.validate(
            .graphPatch(patch),
            request: request
        )
        guard case .committed(
            let kind,
            let identifier,
            .readingGraph(let graph, let expectedSnapshots)
        ) = disposition else {
            return XCTFail("Expected validated graph mutation")
        }
        XCTAssertEqual(kind, "readingGraph")
        XCTAssertEqual(identifier, graph.id)
        XCTAssertNotEqual(identifier, patch.graphID)
        XCTAssertEqual(expectedSnapshots, [
            fixture.imported.source.id: fixture.imported.snapshot.id,
        ])
        XCTAssertNil(try fixture.database.readingGraph(id: graph.id))

        let stale = Locator(
            sourceID: locator.sourceID,
            snapshotID: "stale-snapshot",
            adapterID: locator.adapterID,
            payload: locator.payload,
            structuralPath: locator.structuralPath,
            textQuote: locator.textQuote,
            fingerprint: locator.fingerprint
        )
        let stalePatch = GraphPatch(
            id: "patch-stale",
            schemaVersion: GraphPatch.currentSchemaVersion,
            graphID: "graph-stale",
            baseGraphVersion: nil,
            snapshotIDs: [fixture.imported.snapshot.id],
            upsertUnits: [groundedUnit(locator: stale, sourceID: fixture.imported.source.id)],
            removeUnitIDs: [],
            generatedAt: .now
        )
        do {
            _ = try await fixture.validator.validate(
                .graphPatch(stalePatch),
                request: request
            )
            XCTFail("Expected stale evidence rejection")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .validationRejected("fragment-not-grounded"))
        }
    }

    func testQuickLookCannotSpoofHighConfidenceAndDeterministicPrimaryCommits() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let deterministic = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        )
        let quickLookID = QuickLookAdapter.id
        XCTAssertTrue(deterministic.auxiliaryAdapterIDs.contains(quickLookID))
        let alternateAuxiliary = Array(
            Set(deterministic.auxiliaryAdapterIDs + [deterministic.primaryAdapterID])
                .subtracting([quickLookID])
        ).sorted()
        let spoofed = AdapterPlan(
            id: "agent-spoofed-quicklook",
            schemaVersion: deterministic.schemaVersion,
            sourceID: deterministic.sourceID,
            snapshotID: deterministic.snapshotID,
            primaryAdapterID: quickLookID,
            auxiliaryAdapterIDs: alternateAuxiliary,
            capabilityRoutes: deterministic.capabilityRoutes,
            evidence: deterministic.evidence,
            confidence: 0.99,
            reason: "Model claims that the fallback is highly reliable",
            isUserOverride: false,
            createdAt: .now
        )
        let lowDisposition = try await fixture.validator.validate(
            .adapterPlan(spoofed),
            request: request
        )
        guard case .waitingForUser(let reason, .adapterPlan(let candidate)) = lowDisposition else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertEqual(reason, "adapter-combination-requires-confirmation")
        XCTAssertEqual(candidate.primaryAdapterID, quickLookID)
        XCTAssertEqual(candidate.confidence, 0.1, accuracy: 0.0001)
        XCTAssertNotEqual(candidate.confidence, spoofed.confidence)

        let high = adapterPlan(from: deterministic, id: "agent-high", confidence: 0.9)
        let highDisposition = try await fixture.validator.validate(
            .adapterPlan(high),
            request: request
        )
        guard case .committed(
            let kind,
            let identifier,
            .adapterPlan(let hostPlan)
        ) = highDisposition else {
            return XCTFail("Expected validated adapter mutation")
        }
        XCTAssertEqual(kind, "adapterPlan")
        XCTAssertEqual(identifier, hostPlan.id)
        XCTAssertNotEqual(identifier, "agent-high")
        XCTAssertEqual(hostPlan.createdAt.timeIntervalSinceNow, 0, accuracy: 1)
    }

    func testAdapterProposalRejectsInventedProbeEvidence() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let deterministic = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let original = try XCTUnwrap(deterministic.evidence.first)
        let invented = ProbeEvidence(
            id: original.id,
            adapterID: original.adapterID,
            rule: original.rule,
            detail: "model-invented detail",
            confidence: original.confidence
        )
        let proposal = adapterPlan(
            from: deterministic,
            id: "agent-forged-evidence",
            confidence: 0.95,
            evidence: [invented] + deterministic.evidence.dropFirst()
        )

        do {
            _ = try await fixture.validator.validate(
                .adapterPlan(proposal),
                request: AgentRunRequest(
                    spaceID: fixture.imported.space.id,
                    task: .routeAdapters,
                    targetSourceID: fixture.imported.source.id,
                    targetSnapshotID: fixture.imported.snapshot.id,
                    expectedSnapshotIDs: [fixture.imported.snapshot.id]
                )
            )
            XCTFail("Expected ungrounded probe evidence rejection")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .validationRejected("probe-evidence-not-grounded")
            )
        }
    }

    func testAdapterProposalMustMatchExplicitRouteTarget() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let deterministic = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let proposal = adapterPlan(
            from: deterministic,
            id: "agent-wrong-target",
            confidence: 0.95
        )

        do {
            _ = try await fixture.validator.validate(
                .adapterPlan(proposal),
                request: AgentRunRequest(
                    spaceID: fixture.imported.space.id,
                    task: .routeAdapters,
                    targetSourceID: "different-source",
                    targetSnapshotID: deterministic.snapshotID,
                    expectedSnapshotIDs: [deterministic.snapshotID]
                )
            )
            XCTFail("Expected explicit target mismatch rejection")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .validationRejected("adapter-route-target-mismatch")
            )
        }
    }

    func testEvidenceAnswerRequiresObservedQuote() async throws {
        let fixture = try await makeValidatorFixture()
        defer { fixture.remove() }
        let locator = try XCTUnwrap(fixture.locator)
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .answerWithEvidence,
            question: "What is grounded?",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        )
        let valid = EvidenceAnswer(
            schemaVersion: EvidenceAnswer.currentSchemaVersion,
            answer: "The observed heading is Chapter.",
            citations: [EvidenceCitation(
                id: "citation-valid",
                fragmentID: nil,
                sourceID: fixture.imported.source.id,
                snapshotID: fixture.imported.snapshot.id,
                locator: locator,
                quote: "Chapter"
            )],
            limitations: []
        )
        _ = try await fixture.validator.validate(
            .evidenceAnswer(valid),
            request: request
        )

        let forged = EvidenceAnswer(
            schemaVersion: EvidenceAnswer.currentSchemaVersion,
            answer: "Invented claim.",
            citations: [EvidenceCitation(
                id: "citation-forged",
                fragmentID: nil,
                sourceID: fixture.imported.source.id,
                snapshotID: fixture.imported.snapshot.id,
                locator: locator,
                quote: "This quote never existed"
            )],
            limitations: []
        )
        do {
            _ = try await fixture.validator.validate(
                .evidenceAnswer(forged),
                request: request
            )
            XCTFail("Expected citation rejection")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .validationRejected("citation-not-grounded"))
        }
    }

    private func groundedUnit(locator: Locator, sourceID: String) -> ReadingUnit {
        ReadingUnit(
            id: "unit-\(locator.snapshotID)",
            title: "Grounded chapter",
            summary: "Observed content",
            fragments: [SourceFragment(
                id: "fragment-\(locator.stableID)",
                sourceID: sourceID,
                locator: locator,
                role: .evidence,
                label: "Chapter"
            )],
            relations: [],
            estimatedMinutes: 5,
            importance: 0.8,
            confidence: 0.9,
            sourceOrder: 0,
            preferredPresentation: .markdown
        )
    }

    private func adapterPlan(
        from base: AdapterPlan,
        id: String,
        confidence: Double,
        evidence: [ProbeEvidence]? = nil
    ) -> AdapterPlan {
        AdapterPlan(
            id: id,
            schemaVersion: base.schemaVersion,
            sourceID: base.sourceID,
            snapshotID: base.snapshotID,
            primaryAdapterID: base.primaryAdapterID,
            auxiliaryAdapterIDs: base.auxiliaryAdapterIDs,
            capabilityRoutes: base.capabilityRoutes,
            evidence: evidence ?? base.evidence,
            confidence: confidence,
            reason: "Agent proposal based on registered evidence",
            isUserOverride: false,
            createdAt: .now
        )
    }
}

private struct ValidatorFixture {
    let root: URL
    let inputRoot: URL
    let database: LibraryDatabase
    let imported: ManagedImportResult
    let locator: Locator?
    let validator: AgentOutputValidator

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: inputRoot)
    }
}

private func makeValidatorFixture() async throws -> ValidatorFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OneReader-AgentValidator-\(UUID().uuidString)", isDirectory: true)
    let inputRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("OneReader-AgentValidatorInput-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
    let input = inputRoot.appendingPathComponent("book.md")
    try Data("# Chapter\n\nGrounded evidence for validation.\n".utf8).write(to: input)
    let database = try LibraryDatabase(rootURL: root)
    let library = try ManagedLibrary(
        database: database,
        storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max,
            minimumFreeCapacity: 0,
            capacityProvider: { _ in .max }
        )
    )
    let imported = try await library.importLocalSource(at: input)
    let registry = try AdapterRegistry.standard()
    let coordinator = AdapterCoordinator(database: database, registry: registry)
    let plan = try await coordinator.prepare(
        sourceID: imported.source.id,
        snapshotID: imported.snapshot.id
    )
    let locator = try await coordinator.list(plan: plan, limit: 20).first?.locator
    if let locator {
        _ = try await coordinator.read(plan: plan, locator: locator)
    }
    return ValidatorFixture(
        root: root,
        inputRoot: inputRoot,
        database: database,
        imported: imported,
        locator: locator,
        validator: AgentOutputValidator(database: database, registry: registry)
    )
}
