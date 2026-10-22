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

    private func makeIntentFixture(root: URL) async throws -> IntentTestFixture {
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
        let profile = ProviderProfile(
            displayName: "Intent test provider",
            kind: .appleOnDevice,
            modelID: "intent-test-model",
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
