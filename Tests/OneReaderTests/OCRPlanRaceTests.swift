import AppKit
import Foundation
import GRDB
import XCTest
@testable import OneReader

final class OCRPlanRaceTests: XCTestCase {
    func testLateProbeReprobesInsteadOfActivatingOldOCRRevision() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try publish(fixture, text: "Revision A")
        let gate = ProbeGate()
        let registry = try AdapterRegistry(adapters: [ImageAdapter(), OCRAdapter(database: fixture.database),
            DelayedProbe(gate: gate)])
        let coordinator = AdapterCoordinator(database: fixture.database, registry: registry)
        let task = Task { try await coordinator.prepare(sourceID: fixture.imported.source.id, snapshotID: fixture.imported.snapshot.id) }
        await gate.waitUntilPaused()
        let latest = try publish(fixture, text: "Revision B")
        await gate.release()
        let accepted = try await task.value
        XCTAssertEqual(accepted.evidence.first(where: { $0.rule == "ocr-revision" })?.detail, latest.id)
        XCTAssertEqual(try fixture.database.fetchAdapterPlan(snapshotID: latest.snapshotID)?.id, accepted.id)
        let probeCount = await gate.callCount
        XCTAssertEqual(probeCount, 2, "The old candidate must be retried, not activated")
    }

    func testCompletedOldIndexCannotBeReactivatedAndLatePublicationIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try publish(fixture, text: "OLD_INDEX_ONLY")
        let coordinator = try AdapterCoordinator.standard(database: fixture.database)
        let oldPlan = try await coordinator.prepareAndIndex(sourceID: old.sourceID, snapshotID: old.snapshotID)
        XCTAssertEqual(try fixture.database.searchObservations(query: "OLD_INDEX_ONLY").count, 1)
        let pending = try fixture.database.beginObservationIndex(snapshotID: old.snapshotID, planID: oldPlan.id)
        let observation = try await coordinator.read(plan: oldPlan, locator: old.locator(page: old.pages[0]), persistObservation: false)
        try fixture.database.stageObservation(observation, title: nil, generationID: pending)
        let current = try publish(fixture, text: "NEW_INDEX_ONLY")
        XCTAssertThrowsError(try fixture.database.saveAdapterPlan(oldPlan)) {
            XCTAssertEqual($0 as? LibraryDatabaseError, .staleOCRPlan)
        }
        XCTAssertThrowsError(try fixture.database.completeObservationIndex(snapshotID: old.snapshotID,
            planID: oldPlan.id, generationID: pending))
        XCTAssertTrue(try fixture.database.searchObservations(query: "OLD_INDEX_ONLY").isEmpty)
        let newPlan = try await coordinator.prepareAndIndex(sourceID: current.sourceID, snapshotID: current.snapshotID)
        XCTAssertEqual(try fixture.database.searchObservations(query: "NEW_INDEX_ONLY").first?.locator.payload["ocrRevisionID"], current.id)
        let retained = try await coordinator.read(plan: newPlan, locator: old.locator(page: old.pages[0]))
        XCTAssertEqual(retained.content, "OLD_INDEX_ONLY", "Old evidence remains readable without becoming active search")
    }

    func testBaseProbeWithoutOCRAndForeignRevisionCannotBeIndexedAfterPublication() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try AdapterCoordinator.standard(database: fixture.database)
        let base = try await coordinator.prepare(sourceID: fixture.imported.source.id, snapshotID: fixture.imported.snapshot.id)
        _ = try publish(fixture, text: "Current revision")
        XCTAssertThrowsError(try fixture.database.saveAdapterPlan(base))
        let plan = try await coordinator.prepare(sourceID: fixture.imported.source.id, snapshotID: fixture.imported.snapshot.id)
        let generation = try fixture.database.beginObservationIndex(snapshotID: plan.snapshotID, planID: plan.id)
        let forged = Locator(sourceID: plan.sourceID, snapshotID: plan.snapshotID, adapterID: OCRAdapter.id,
            payload: ["ocrRevisionID": "foreign", "pageIndex": "0", "ocrSchema": "1"])
        let observation = Observation(id: "forged-observation", sourceID: plan.sourceID, snapshotID: plan.snapshotID, adapterID: OCRAdapter.id,
            locator: forged, mediaType: "text/plain; derived=ocr", content: "FORGED_INDEX",
            contentReference: nil, contentDigest: AdapterUtilities.sha256("FORGED_INDEX"), truncated: false, observedAt: .now)
        XCTAssertThrowsError(try fixture.database.stageObservation(observation, title: nil, generationID: generation))
    }

    func testStartupInvalidatesLegacyStalePlanWithoutDeletingItsEvidence() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try publish(fixture, text: "Legacy stale index")
        let coordinator = try AdapterCoordinator.standard(database: fixture.database)
        let oldPlan = try await coordinator.prepareAndIndex(sourceID: old.sourceID, snapshotID: old.snapshotID)
        let current = try publish(fixture, text: "Current revision")
        // Reproduce a pre-fix late write without using the guarded production API.
        try await fixture.database.pool.write { db in
            try db.execute(sql: "INSERT INTO active_adapter_plans (snapshot_id, plan_id, updated_at) VALUES (?, ?, ?)",
                arguments: [old.snapshotID, oldPlan.id, Date.now])
        }
        XCTAssertNil(try fixture.database.fetchAdapterPlan(snapshotID: old.snapshotID))
        let recovered = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        let activeCount = try await recovered.pool.read { try Int.fetchOne($0,
            sql: "SELECT COUNT(*) FROM active_adapter_plans WHERE snapshot_id = ?", arguments: [old.snapshotID]) }
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(try recovered.ocrRevision(id: old.id, sourceID: old.sourceID, snapshotID: old.snapshotID)?.id, old.id)
        XCTAssertEqual(try recovered.activeOCRRevision(snapshotID: current.snapshotID)?.id, current.id)
        XCTAssertTrue(try recovered.searchObservations(query: "Legacy stale index").isEmpty)
        let historyCount = try await recovered.pool.read { try Int.fetchOne($0,
            sql: "SELECT COUNT(*) FROM adapter_plans WHERE id = ?", arguments: [oldPlan.id]) }
        XCTAssertEqual(historyCount, 1)
    }

    func testAgentFinalizationCannotBypassOCRRevisionCompareAndSwap() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try publish(fixture, text: "Agent candidate revision")
        let coordinator = try AdapterCoordinator.standard(database: fixture.database)
        let candidate = try await coordinator.prepare(sourceID: old.sourceID, snapshotID: old.snapshotID)
        let manifest = try fixture.database.currentSnapshotManifest(spaceID: fixture.imported.space.id)
        let request = AgentRunRequest(spaceID: fixture.imported.space.id, task: .routeAdapters,
            targetSourceID: old.sourceID, targetSnapshotID: old.snapshotID,
            expectedSnapshotIDs: Set(manifest.values), snapshotManifest: manifest)
        let run = AgentRun(id: UUID().uuidString, spaceID: request.spaceID, task: request.task,
            generation: 1, state: .queued, providerProfileID: nil, createdAt: .now,
            startedAt: nil, finishedAt: nil, errorCategory: nil)
        try fixture.database.beginAgentRun(run, request: request)
        try fixture.database.markAgentRunRunningCAS(id: run.id, spaceID: run.spaceID, generation: run.generation)
        _ = try publish(fixture, text: "Newer host revision")
        let output = PersistedAgentOutput(runID: run.id, kind: "adapterPlan", output: .adapterPlan(candidate),
            disposition: "committed", createdAt: .now)
        let event = AgentEvent(id: UUID().uuidString, runID: run.id, sequence: 1, kind: .completed,
            phase: "commit", message: "must reject stale candidate", metadata: [:], createdAt: .now)
        XCTAssertThrowsError(try fixture.database.finalizeAgentRun(runID: run.id, spaceID: run.spaceID,
            generation: run.generation, manifest: manifest, output: output, finalState: .completed,
            errorCategory: nil, mutation: .adapterPlan(candidate), event: event)) {
            XCTAssertEqual($0 as? LibraryDatabaseError, .staleOCRPlan)
        }
        XCTAssertNil(try fixture.database.agentOutput(runID: run.id))
        XCTAssertNil(try fixture.database.fetchAdapterPlan(snapshotID: old.snapshotID))
        XCTAssertEqual(try fixture.database.fetchAgentRuns().first(where: { $0.id == run.id })?.state, .running)
        XCTAssertEqual(try fixture.database.fetchAgentEvents(runID: run.id).map(\.kind), [.queued])
    }

    private struct Fixture {
        let root: URL
        let database: LibraryDatabase
        let imported: ManagedImportResult
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-PlanRace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(bitmap.makeImage())).representation(using: .png, properties: [:])).write(to: file)
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }))
        let imported = try await library.importLocalSource(at: file)
        return Fixture(root: root, database: database, imported: imported)
    }

    private func publish(_ fixture: Fixture, text: String) throws -> OCRRevision {
        let source = fixture.imported.source; let snapshot = fixture.imported.snapshot
        let job = OCRJob(id: UUID().uuidString, sourceID: source.id, snapshotID: snapshot.id, pageIndices: [0],
            settings: OCRSettings(), completedPages: [], failedPages: [], state: .running, createdAt: .now, updatedAt: .now)
        try fixture.database.startOCRJob(job)
        let page = OCRPage(pageIndex: 0, inputDigest: snapshot.digest,
            geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), pixelWidth: 80, pixelHeight: 80,
                transform: CGAffineTransform(scaleX: 80, y: 80)),
            spans: [OCRSpan(id: UUID().uuidString, text: text, confidence: 1,
                bounds: OCRRectangle(CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.1)), order: 0)], usesNativeText: false)
        _ = try fixture.database.saveOCRPage(page, jobID: job.id)
        return try XCTUnwrap(fixture.database.finishOCRJob(job.id, state: .completed))
    }
}

private actor ProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    func pauseOnce() async {
        callCount += 1
        guard callCount == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct DelayedProbe: ProbingAdapter {
    let gate: ProbeGate
    let descriptor = AdapterDescriptor(id: "zz.delayed-ocr-probe", version: "1", displayName: "Test only",
        probeRule: AdapterProbeRule(filenameExtensions: [], mediaTypes: [], sourceOrigins: [], magicPrefixes: []),
        capabilities: [.probe], limitations: [])
    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? { await gate.pauseOnce(); return nil }
}
