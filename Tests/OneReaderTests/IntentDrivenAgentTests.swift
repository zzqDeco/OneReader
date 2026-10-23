import Foundation
import XCTest
@testable import OneReader

@MainActor
final class IntentDrivenAgentTests: XCTestCase {
    func testAnnotationAnchorStateLocalizedBadgeTitle() {
        XCTAssertNil(AnnotationAnchorState.current.localizedBadgeTitle)
        XCTAssertEqual(AnnotationAnchorState.relocated.localizedBadgeTitle, "已对齐新版本")
        XCTAssertEqual(AnnotationAnchorState.orphaned.localizedBadgeTitle, "原文已变动")
    }

    func testLaunchIntentAgentPipelineSkipsHighConfidenceRoutingAndProjectsSelectedGoal() async throws {
        let root = temporaryRoot("IntentPipeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIntentFixture(root: root)

        let installedPlan = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        XCTAssertGreaterThanOrEqual(installedPlan.confidence, 0.85)
        XCTAssertTrue(
            AppModel.shouldSkipAdapterRouting(
                installedPlan: installedPlan,
                skipHighConfidenceRouting: true
            )
        )

        let unitID = "intent-unit-1"
        let patch = GraphPatch(
            id: "intent-patch-1",
            schemaVersion: GraphPatch.currentSchemaVersion,
            graphID: "intent-graph-1",
            baseGraphVersion: nil,
            snapshotIDs: [fixture.imported.snapshot.id],
            upsertUnits: [
                ReadingUnit(
                    id: unitID,
                    title: "Core Evidence Section",
                    summary: "Grounded summary of core evidence.",
                    fragments: [
                        SourceFragment(
                            id: "intent-fragment-1",
                            sourceID: fixture.imported.source.id,
                            locator: fixture.observation.locator,
                            role: .primary,
                            label: "Session"
                        )
                    ],
                    relations: [],
                    estimatedMinutes: 5,
                    importance: 0.9,
                    confidence: 0.95,
                    sourceOrder: 0,
                    preferredPresentation: .markdown
                )
            ],
            removeUnitIDs: [],
            generatedAt: .now
        )

        let trace = IntentAgentTrace()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore(),
            agentDriverFactory: IntentAgentDriverFactory(
                patch: patch,
                orderedUnitIDs: [unitID],
                answer: fixture.answer,
                trace: trace
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activeProvider != nil
        }

        model.selectReadingGoal(.quickOverview)
        XCTAssertEqual(model.selectedReadingGoal, .quickOverview)
        XCTAssertEqual(model.currentProgress.activeGoal, .quickOverview)
        XCTAssertEqual(model.effectiveReadingGoalPrompt, ReadingGoal.quickOverview.rawValue)

        model.launchIntentAgentPipeline(skipHighConfidenceRouting: true)
        try await waitUntil(timeout: .seconds(5)) {
            model.currentPlan?.goal == ReadingGoal.quickOverview.rawValue
        }

        let initialRecords = await trace.records()
        XCTAssertEqual(
            initialRecords.map(\.task),
            [.scoutSpace, .materializeGraph, .projectRoute],
            "High-confidence deterministic AdapterPlan should skip redundant .routeAdapters call"
        )
        XCTAssertEqual(initialRecords.last?.goal, ReadingGoal.quickOverview.rawValue)
        XCTAssertEqual(model.currentProgress.activeGoal, .quickOverview)
        XCTAssertEqual(model.currentGraph?.units.map(\.id), [unitID])

        // Re-project route directly on the existing ReadingGraph with a custom focus prompt
        model.selectReadingGoal(.review)
        model.customReadingGoalText = "  重点排查安全边界  "
        XCTAssertEqual(model.effectiveReadingGoalPrompt, "custom:重点排查安全边界")

        model.reprojectReadingRouteForSelectedGoal()
        try await waitUntil(timeout: .seconds(5)) {
            model.currentPlan?.goal == "custom:重点排查安全边界"
        }

        let allRecords = await trace.records()
        XCTAssertEqual(
            allRecords.map(\.task),
            [.scoutSpace, .materializeGraph, .projectRoute, .projectRoute]
        )
        XCTAssertEqual(allRecords.last?.goal, "custom:重点排查安全边界")
        XCTAssertEqual(model.currentProgress.activeGoal, .review)
    }

    func testLoadEvidenceQAHistoryAndSaveEvidenceQAAsNote() async throws {
        let root = temporaryRoot("IntentQANote")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeIntentFixture(root: root)

        let trace = IntentAgentTrace()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
        let model = AppModel(
            libraryRootURL: fixture.libraryRoot,
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore(),
            agentDriverFactory: IntentAgentDriverFactory(
                patch: nil,
                orderedUnitIDs: [],
                answer: fixture.answer,
                trace: trace
            )
        )
        try await waitUntil { model.isBootstrapComplete }
        model.openSpace(fixture.imported.space.id)
        try await waitUntil(timeout: .seconds(5)) {
            model.presentationDocument != nil && model.activeProvider != nil
        }

        let question = "这段材料的核心证据是什么？"
        model.askAgent(question)
        try await waitUntil(timeout: .seconds(5)) {
            model.evidenceAnswer == fixture.answer && !model.evidenceQAHistory.isEmpty
        }

        XCTAssertEqual(model.evidenceQAHistory.count, 1)
        let qa = try XCTUnwrap(model.evidenceQAHistory.first)
        XCTAssertEqual(qa.spaceID, fixture.imported.space.id)
        XCTAssertEqual(qa.question, question)
        XCTAssertEqual(qa.answer, fixture.answer)

        // Verify loadEvidenceQAHistory reloads from persisted AgentRun + AgentOutput
        model.evidenceQAHistory = []
        model.loadEvidenceQAHistory(spaceID: fixture.imported.space.id)
        XCTAssertEqual(model.evidenceQAHistory.count, 1)
        XCTAssertEqual(model.evidenceQAHistory.first?.question, question)
        XCTAssertEqual(model.evidenceQAHistory.first?.answer, fixture.answer)

        // Save the completed Q&A turn as a grounded note Annotation
        model.saveEvidenceQAAsNote(qa)
        XCTAssertEqual(model.annotations.count, 1)
        let annotation = try XCTUnwrap(model.annotations.first)
        XCTAssertEqual(annotation.kind, .note)
        XCTAssertEqual(annotation.spaceID, fixture.imported.space.id)
        XCTAssertEqual(annotation.sourceID, fixture.imported.source.id)
        XCTAssertEqual(annotation.snapshotID, fixture.imported.snapshot.id)
        XCTAssertEqual(annotation.locator, fixture.observation.locator)
        XCTAssertEqual(annotation.selectedText, "Evidence.")
        XCTAssertEqual(
            annotation.note,
            "【研读问答】\(question)\n\(fixture.answer.answer)"
        )
        XCTAssertEqual(annotation.anchorState, .current)
        XCTAssertEqual(model.notice?.title, "已存为证据笔记")

        let persisted = try fixture.database.fetchAnnotations(spaceID: fixture.imported.space.id)
        XCTAssertEqual(persisted, [annotation])

        // A persisted answer remains evidence for v1 after a refresh changes its
        // context. Opening it must neither show v2 nor move v2's reading position.
        let input = root.appendingPathComponent("Inputs/intent.md")
        try Data("# Session\n\nChanged context for the second edition.\n\nEvidence.\n".utf8).write(to: input)
        model.refreshSource(fixture.imported.source.id)
        try await waitUntil(timeout: .seconds(8)) {
            !model.refreshingSourceIDs.contains(fixture.imported.source.id)
                && model.selectedSnapshot?.id != fixture.imported.snapshot.id
                && model.presentationDocument != nil
        }
        let currentSnapshotID = try XCTUnwrap(model.selectedSnapshot?.id)
        model.flushReadingPosition()
        let currentPosition = try fixture.database.fetchReadingProgress(spaceID: qa.spaceID)
            .sourcePositions[fixture.imported.source.id]

        model.openEvidenceCitation(try XCTUnwrap(qa.answer.citations.first?.locator))
        try await waitUntil {
            model.isAnnotationPreview && model.presentationDocument?.locator.snapshotID == fixture.imported.snapshot.id
        }
        XCTAssertFalse(model.presentationDocument?.content?.contains("Changed context") ?? true)
        model.flushReadingPosition()
        XCTAssertEqual(
            try fixture.database.fetchReadingProgress(spaceID: qa.spaceID).sourcePositions[fixture.imported.source.id],
            currentPosition
        )
        XCTAssertEqual(model.source(id: fixture.imported.source.id)?.latestSnapshotID, currentSnapshotID)

        let basePlan = try XCTUnwrap(fixture.database.fetchAdapterPlan(snapshotID: currentSnapshotID))
        let adoptedPlan = AdapterPlan(id: "agent-adapter-plan:adopted-current", schemaVersion: basePlan.schemaVersion,
            sourceID: basePlan.sourceID, snapshotID: basePlan.snapshotID, primaryAdapterID: basePlan.primaryAdapterID,
            auxiliaryAdapterIDs: basePlan.auxiliaryAdapterIDs, capabilityRoutes: basePlan.capabilityRoutes,
            evidence: basePlan.evidence, confidence: 1, reason: "User-adopted plan", isUserOverride: true, createdAt: .now)
        try fixture.database.saveAdapterPlan(adoptedPlan)
        let persistedAdoptedPlan = try XCTUnwrap(fixture.database.fetchAdapterPlan(snapshotID: currentSnapshotID))
        let coordinator = try AdapterCoordinator.standard(database: fixture.database)
        try await coordinator.index(plan: adoptedPlan)
        let activeHits = try fixture.database.searchObservations(query: "Evidence", snapshotID: currentSnapshotID, planID: adoptedPlan.id)
        XCTAssertFalse(activeHits.isEmpty)
        model.saveEvidenceQAAsNote(qa)
        try await waitUntil { model.annotations.count == 2 }
        let historicalNote = try XCTUnwrap(model.annotations.first { $0.id != annotation.id })
        XCTAssertEqual(historicalNote.snapshotID, fixture.imported.snapshot.id)
        XCTAssertEqual(historicalNote.locator, qa.answer.citations.first?.locator)
        XCTAssertEqual(historicalNote.anchorState, .relocated)
        XCTAssertEqual(try fixture.database.fetchAdapterPlan(snapshotID: currentSnapshotID), persistedAdoptedPlan)
        XCTAssertEqual(try fixture.database.searchObservations(query: "Evidence", snapshotID: currentSnapshotID, planID: adoptedPlan.id), activeHits)

        // Even a path-only citation must not be called aligned when the cited
        // passage is absent. The retained original remains readable regardless.
        model.openSource(fixture.imported.source.id)
        try await waitUntil { !model.isAnnotationPreview && model.selectedSnapshot?.id == currentSnapshotID }
        try Data("# Session\n\nThe cited passage has been removed.\n".utf8).write(to: input)
        model.refreshSource(fixture.imported.source.id)
        try await waitUntil(timeout: .seconds(8)) {
            !model.refreshingSourceIDs.contains(fixture.imported.source.id)
                && model.selectedSnapshot?.id != currentSnapshotID
                && model.presentationDocument != nil
        }
        model.saveEvidenceQAAsNote(qa)
        try await waitUntil { model.annotations.count == 3 }
        let removedPassageNote = try XCTUnwrap(model.annotations.first {
            $0.id != annotation.id && $0.id != historicalNote.id
        })
        XCTAssertEqual(removedPassageNote.anchorState, .orphaned)
        XCTAssertEqual(removedPassageNote.locator, qa.answer.citations.first?.locator)
        model.openEvidenceCitation(try XCTUnwrap(qa.answer.citations.first?.locator))
        try await waitUntil { model.isAnnotationPreview && model.presentationDocument?.locator.snapshotID == fixture.imported.snapshot.id }
        XCTAssertTrue(model.presentationDocument?.content?.contains("Evidence.") == true)
    }

    func testIntentRoutingPolicyRoundTripsAndLegacyRequestsDecodeWithoutIt() throws {
        let request = AgentRunRequest(spaceID: "space", task: .scoutSpace,
            pipeline: .readingStructure, goal: "custom:original goal", skipHighConfidenceRouting: false)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(AgentRunRequest.self, from: data), request)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "skipHighConfidenceRouting")
        let decoded = try JSONDecoder().decode(AgentRunRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.skipHighConfidenceRouting)
        XCTAssertEqual(decoded.goal, request.goal)
    }

    func testIntentGoalAndRoutingPolicySurviveRemoteDisclosureAndPersistedResume() async throws {
        for goal in [ReadingGoal.quickOverview.rawValue, "custom:compare the evidence"] {
            let root = temporaryRoot("IntentDisclosure")
            defer { try? FileManager.default.removeItem(at: root) }
            let secrets = InMemoryProviderSecretStore()
            let fixture = try await makeIntentFixture(root: root, providerKind: .openAIResponses, secrets: secrets)
            let patch = GraphPatch(
                id: "disclosure-patch", schemaVersion: GraphPatch.currentSchemaVersion,
                graphID: "disclosure-graph", baseGraphVersion: nil,
                snapshotIDs: [fixture.imported.snapshot.id],
                upsertUnits: [ReadingUnit(
                    id: "disclosure-unit", title: "Evidence", summary: "Grounded evidence",
                    fragments: [SourceFragment(id: "disclosure-fragment", sourceID: fixture.imported.source.id,
                        locator: fixture.observation.locator, role: .primary, label: "Evidence")],
                    relations: [], estimatedMinutes: 1, importance: 1, confidence: 1,
                    sourceOrder: 0, preferredPresentation: .markdown
                )], removeUnitIDs: [], generatedAt: .now
            )
            let trace = IntentAgentTrace()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "OneReaderTests.\(UUID().uuidString)"))
            let model = AppModel(libraryRootURL: fixture.libraryRoot, defaults: defaults,
                secretStore: secrets, agentDriverFactory: IntentAgentDriverFactory(
                    patch: patch, orderedUnitIDs: ["disclosure-unit"], answer: fixture.answer, trace: trace))
            try await waitUntil { model.isBootstrapComplete }
            model.openSpace(fixture.imported.space.id)
            try await waitUntil { model.presentationDocument != nil && model.activeProvider != nil }
            model.selectReadingGoal(.quickOverview)
            if goal.hasPrefix("custom:") { model.customReadingGoalText = String(goal.dropFirst(7)) }
            model.launchIntentAgentPipeline(skipHighConfidenceRouting: true)
            try await waitUntil { model.waitingAgentAttentionKind == .disclosure }
            let waiting = try XCTUnwrap(model.waitingAgentRun)
            let persistedRequest = try XCTUnwrap(fixture.database.request(forRunID: waiting.id))
            XCTAssertEqual(persistedRequest.goal, goal)
            XCTAssertEqual(persistedRequest.skipHighConfidenceRouting, true)
            let beforeConsent = await trace.records()
            XCTAssertTrue(beforeConsent.isEmpty)

            // UI preferences can change while consent is pending; continuation
            // must use the saved request, not those new preferences.
            model.selectReadingGoal(.review)
            model.customReadingGoalText = "unrelated new draft"
            model.confirmWaitingAgentRun()
            try await waitUntil(timeout: .seconds(8)) { model.currentPlan?.goal == goal }
            let records = await trace.records()
            XCTAssertEqual(records.map(\.task), [.scoutSpace, .materializeGraph, .projectRoute])
            XCTAssertTrue(records.allSatisfy { $0.goal == goal })
            for run in try fixture.database.fetchAgentRuns(spaceID: fixture.imported.space.id) {
                let request = try XCTUnwrap(fixture.database.request(forRunID: run.id))
                XCTAssertEqual(request.goal, goal)
                XCTAssertEqual(request.skipHighConfidenceRouting, true)
            }
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderIntent-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeIntentFixture(
        root: URL,
        providerKind: ProviderKind = .appleOnDevice,
        secrets: InMemoryProviderSecretStore = InMemoryProviderSecretStore()
    ) async throws -> IntentTestFixture {
        let inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let input = inputs.appendingPathComponent("intent.md")
        try Data("# Session\n\nEvidence.\n".utf8).write(to: input)
        let database = try LibraryDatabase(rootURL: libraryRoot)
        let library = try ManagedLibrary(
            database: database,
            storagePolicy: LibraryStoragePolicy(
                largeImportThreshold: .max,
                minimumFreeCapacity: 0,
                capacityProvider: { _ in .max }
            )
        )
        let imported = try await library.importLocalSource(at: input)
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        let nodes = try await coordinator.list(plan: plan)
        let node = try XCTUnwrap(nodes.first)
        var rootPayload = node.locator.payload
        rootPayload["startLine"] = nil
        rootPayload["endLine"] = nil
        rootPayload["headingLevel"] = nil
        let rootLocator = Locator(
            sourceID: node.locator.sourceID,
            snapshotID: node.locator.snapshotID,
            adapterID: node.locator.adapterID,
            payload: rootPayload
        )
        let observation = try await coordinator.read(plan: plan, locator: rootLocator)
        let keyReference = providerKind.requiresSecret
            ? await secrets.save(secret: "fake-intent-test-key", reference: nil) : nil
        let profile = ProviderProfile(
            displayName: "Intent test provider",
            kind: providerKind,
            endpoint: providerKind == .openAIResponses ? URL(string: "https://example.invalid/v1") : nil,
            modelID: "intent-test-model",
            keychainReference: keyReference,
            isDefault: true,
            capabilities: [.connection, .structuredGeneration, .toolCalling],
            lastTestedAt: .now,
            lastTestSucceeded: true
        )
        try database.saveProviderProfile(profile)
        let answer = EvidenceAnswer(
            schemaVersion: EvidenceAnswer.currentSchemaVersion,
            answer: "The source contains grounded evidence.",
            citations: [
                EvidenceCitation(
                    id: "intent-citation-1",
                    fragmentID: nil,
                    sourceID: imported.source.id,
                    snapshotID: imported.snapshot.id,
                    locator: observation.locator,
                    quote: "Evidence."
                )
            ],
            limitations: []
        )
        return IntentTestFixture(
            libraryRoot: libraryRoot,
            database: database,
            imported: imported,
            observation: observation,
            answer: answer
        )
    }
}

private struct IntentTestFixture {
    let libraryRoot: URL
    let database: LibraryDatabase
    let imported: ManagedImportResult
    let observation: Observation
    let answer: EvidenceAnswer
}

private actor IntentAgentTrace {
    struct Record: Equatable, Sendable {
        let task: AgentTaskKind
        let goal: String?
        let targetSourceID: String?
    }

    private var values: [Record] = []

    func append(_ record: Record) {
        values.append(record)
    }

    func records() -> [Record] { values }
}

private struct IntentAgentDriverFactory: ReadingAgentDriverFactory {
    let patch: GraphPatch?
    let orderedUnitIDs: [String]
    let answer: EvidenceAnswer
    let trace: IntentAgentTrace

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        IntentAgentDriver(
            context: context,
            patch: patch,
            orderedUnitIDs: orderedUnitIDs,
            answer: answer,
            trace: trace
        )
    }
}

private struct IntentAgentDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let patch: GraphPatch?
    let orderedUnitIDs: [String]
    let answer: EvidenceAnswer
    let trace: IntentAgentTrace

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        await trace.append(
            .init(
                task: request.request.task,
                goal: request.request.goal,
                targetSourceID: request.request.targetSourceID
            )
        )
        switch request.request.task {
        case .scoutSpace:
            return AgentModelResult(
                output: .scoutingSummary("Scouting summary for intent pipeline."),
                usage: nil
            )
        case .materializeGraph:
            guard let patch else {
                throw ReadingAgentError.providerUnavailable("missing-patch")
            }
            return AgentModelResult(output: .graphPatch(patch), usage: nil)
        case .projectRoute:
            guard let graph = try context.database.latestReadingGraph(spaceID: request.request.spaceID) else {
                throw ReadingAgentError.validationRejected("missing-latest-graph")
            }
            let goal = request.request.goal ?? ReadingGoal.systematic.rawValue
            let draft = ReadingPlanDraft(
                id: "intent-plan-\(UUID().uuidString.lowercased())",
                schemaVersion: ReadingPlanDraft.currentSchemaVersion,
                graphID: graph.id,
                graphVersion: graph.version,
                goal: goal,
                orderedUnitIDs: orderedUnitIDs,
                reasons: Dictionary(uniqueKeysWithValues: orderedUnitIDs.map { ($0, "Reason for \(goal)") }),
                createdAt: .now
            )
            return AgentModelResult(output: .readingPlan(draft), usage: nil)
        case .answerWithEvidence:
            return AgentModelResult(output: .evidenceAnswer(answer), usage: nil)
        case .routeAdapters, .translateFragments:
            throw ReadingAgentError.providerUnavailable(
                "unexpected-task-\(request.request.task.rawValue)"
            )
        }
    }
}
