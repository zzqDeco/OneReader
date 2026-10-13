import Foundation
import GRDB
import XCTest
@testable import OneReader

@MainActor
final class CaptureInboxTests: XCTestCase {
    func testURLReceiptIsDurableWithoutNetworkOrProvider() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        CaptureURLProtocol.configure(offline: true)
        let receipt = try await fixture.coordinator.receive(.remote(URL(string: "https://example.com/article?private=retained-only-in-receipt")!))
        XCTAssertEqual(CaptureURLProtocol.requestCount, 0)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .received)
        XCTAssertTrue(try fixture.database.fetchSources().isEmpty)
        let restored = try LibraryDatabase(rootURL: fixture.database.layout.rootURL)
        XCTAssertEqual(try restored.captureJob(receipt.id)?.receipt, receipt)
        _ = await fixture.coordinator.process(receipt.id)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .waitingForImport)
        XCTAssertFalse(try XCTUnwrap(fixture.database.captureJob(receipt.id)?.errorMessage).contains("private"))
        XCTAssertTrue(try fixture.database.fetchSources().isEmpty)

        CaptureURLProtocol.configure(offline: false)
        let result = await fixture.coordinator.process(receipt.id)
        XCTAssertNotNil(result)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .ready)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
        XCTAssertEqual(result?.imported.space.organizationState, .inbox)
    }

    func testFileReceiptSurvivesOriginalRemovalAndReplaysWithoutDuplicateIdentity() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let input = try fixture.file("offline.md", "# 离线\n\n保留文本。")
        let receipt = try await fixture.coordinator.receive(.local(input))
        try FileManager.default.removeItem(at: input)
        let result = try await fixture.process(receipt.id)
        XCTAssertEqual(try String(contentsOf: result.imported.managedURL, encoding: .utf8), "# 离线\n\n保留文本。")
        XCTAssertNil(result.imported.source.originURL, "A provider's temporary path must not pretend to be a refreshable origin")
        let sourceID = result.imported.source.id
        try await fixture.coordinator.recover()
        let replay = await fixture.coordinator.process(receipt.id)
        XCTAssertNil(replay)
        XCTAssertEqual(try fixture.database.fetchSources().map(\.id), [sourceID])
        XCTAssertEqual(try fixture.database.fetchSpaces().count, 1)
    }

    func testCrashAfterStagingBeforeDatabaseCommitRestoresReceipt() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try fixture.staging.receiveFile(try fixture.file("crash.txt", "durable input"))
        XCTAssertNil(try fixture.database.captureJob(receipt.id))
        try await fixture.coordinator.recover()
        XCTAssertNotNil(try fixture.database.captureJob(receipt.id))
        _ = try await fixture.process(receipt.id)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testCrashAfterImportTransactionResumesSameSourceSnapshotAndSpace() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("crash.md", "# committed")))
        let claim = try XCTUnwrap(fixture.database.claimCapture(receipt.id))
        let payload = try XCTUnwrap(fixture.staging.payloadURL(for: receipt))
        let imported = try await fixture.library.importLocalSource(at: payload, capture: claim)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .preparing)
        try await fixture.coordinator.recover()
        let resumed = try await fixture.process(receipt.id)
        XCTAssertEqual(resumed.imported.source.id, imported.source.id)
        XCTAssertEqual(resumed.imported.snapshot.id, imported.snapshot.id)
        XCTAssertEqual(resumed.imported.space.id, imported.space.id)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testDuplicateReceiptsAndConcurrentClaimsAreIdempotent() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let id = UUID().uuidString.lowercased()
        let url = URL(string: "https://example.com/idempotent")!
        let first = try fixture.staging.receiveURL(url, id: id)
        let again = try fixture.staging.receiveURL(url, id: id)
        XCTAssertEqual(first, again)
        try fixture.database.receiveCapture(first)
        try fixture.database.receiveCapture(again)
        let database = fixture.database
        let claims = try await withThrowingTaskGroup(of: CaptureImportContext?.self) { group in
            for _ in 0..<12 { group.addTask { try database.claimCapture(id) } }
            var values: [CaptureImportContext] = []
            for try await value in group { if let value { values.append(value) } }
            return values
        }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(try fixture.database.captureJobs().count, 1)
        XCTAssertThrowsError(try fixture.staging.receiveURL(URL(string: "https://example.com/different")!, id: id))
    }

    func testCancellationInvalidatesClaimBeforeSourceCreationAndAllowsRetry() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("cancel.txt", "cancel safe")))
        let claim = try XCTUnwrap(fixture.database.claimCapture(receipt.id))
        try fixture.database.cancelCapture(receipt.id)
        let payload = try XCTUnwrap(fixture.staging.payloadURL(for: receipt))
        do {
            _ = try await fixture.library.importLocalSource(at: payload, capture: claim)
            XCTFail("Cancelled generation must not commit a source")
        } catch { XCTAssertEqual(error as? CaptureError, .noLongerActive) }
        XCTAssertTrue(try fixture.database.fetchSources().isEmpty)
        try fixture.database.retryCapture(receipt.id)
        _ = try await fixture.process(receipt.id)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testCancelAfterImportKeepsIdentityAndDoesNotAutoResume() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("partial.txt", "saved")))
        let claim = try XCTUnwrap(fixture.database.claimCapture(receipt.id))
        let imported = try await fixture.library.importLocalSource(
            at: try XCTUnwrap(fixture.staging.payloadURL(for: receipt)), capture: claim
        )
        try fixture.database.cancelCapture(receipt.id)
        try await fixture.coordinator.recover()
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .cancelled)
        try fixture.database.retryCapture(receipt.id)
        let result = try await fixture.process(receipt.id)
        XCTAssertEqual(result.imported.source.id, imported.source.id)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testSharedHandoffIsAcknowledgedOnlyAfterLocalDurableCopy() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let shared = fixture.store("Shared")
        let receipt = try shared.receiveFile(try fixture.file("share.txt", "shared"))
        let coordinator = fixture.makeCoordinator(shared: shared)
        let failed = try await coordinator.receiveSharedHandoffs()
        XCTAssertEqual(failed, 0)
        XCTAssertTrue(try shared.receipts().isEmpty)
        XCTAssertEqual(try fixture.staging.receipt(id: receipt.id), receipt)
        let copiedPaths = try FileManager.default.subpathsOfDirectory(atPath: fixture.staging.rootURL.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.staging.rootURL.appendingPathComponent("ready/\(receipt.id)/payload/share.txt").path),
            "Adopted paths: \(copiedPaths)"
        )
        XCTAssertNotNil(try fixture.database.captureJob(receipt.id))
        let processed = await coordinator.process(receipt.id)
        let processedJob = try fixture.database.captureJob(receipt.id)
        XCTAssertNotNil(processed, String(describing: processedJob))

        // Replay an acknowledged directory (extension retry/crash) without duplicate source.
        _ = try shared.receiveFile(try fixture.file("share.txt", "shared"), id: receipt.id)
        let replayFailures = try await coordinator.receiveSharedHandoffs()
        XCTAssertEqual(replayFailures, 0)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testPartialBatchLeavesInvalidHandoffUntouchedAndImportsValidOne() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let shared = fixture.store("Shared")
        let valid = try shared.receiveURL(URL(string: "https://example.com/valid")!)
        let invalidID = UUID().uuidString.lowercased()
        let bad = shared.rootURL.appendingPathComponent("ready/\(invalidID)")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("invalid receipt".utf8).write(to: bad.appendingPathComponent("receipt.json"))
        let coordinator = fixture.makeCoordinator(shared: shared)
        let failed = try await coordinator.receiveSharedHandoffs()
        XCTAssertEqual(failed, 1)
        XCTAssertNotNil(try fixture.database.captureJob(valid.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertEqual(try fixture.database.captureJobs().count, 1)
    }

    func testUnsafeURLFileSizeAndCapacityAreRejectedBeforeReceipt() throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        for url in ["http://example.com", "file:///etc/passwd", "https://user:password@example.com/"] {
            XCTAssertThrowsError(try fixture.staging.receiveURL(URL(string: url)!))
        }
        let file = try fixture.file("bounded.txt", String(repeating: "x", count: 100))
        var bounded = fixture.store("Bounded")
        bounded.maximumBytes = 10
        XCTAssertThrowsError(try bounded.receiveFile(file))
        XCTAssertTrue(try bounded.receipts().isEmpty)
        var noSpace = fixture.store("NoSpace")
        noSpace.capacity = { _ in CaptureStagingStore.minimumFreeCapacity }
        XCTAssertThrowsError(try noSpace.receiveFile(file))
        XCTAssertTrue(try noSpace.receipts().isEmpty)
        let link = fixture.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try fixture.staging.receiveFile(link))
        XCTAssertThrowsError(try fixture.staging.receiveFile(try fixture.file("payload.exe", "bad")))
    }

    func testLocalCompanionResourcesAndDirectoryContentSurviveCapture() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.file("diagram.png", "generated image bytes")
        let input = try fixture.file("resources.md", "# Local\n\n![Image](diagram.png)")
        let receipt = try await fixture.coordinator.receive(.local(input))
        let result = try await fixture.process(receipt.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.imported.managedURL.deletingLastPathComponent().appendingPathComponent("diagram.png").path))
        let tree = fixture.root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("# Repo".utf8).write(to: tree.appendingPathComponent("README.md"))
        let directoryReceipt = try await fixture.coordinator.receive(.local(tree))
        _ = try await fixture.process(directoryReceipt.id)
    }

    func testArchiveReadAndUnarchivePreserveEveryEvidenceAndProgressIdentity() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("progress.md", "# Progress\n\nBody")))
        let result = try await fixture.process(receipt.id)
        let imported = result.imported
        let locator = Locator(sourceID: imported.source.id, snapshotID: imported.snapshot.id, adapterID: "markdown", payload: ["startLine": "2"])
        var progress = ReadingProgress.empty
        progress.sourcePositions[imported.source.id] = SourcePosition(
            sourceID: imported.source.id, locator: locator, updatedAt: .now,
            progressFraction: 0.42, granularity: .text, displayLabel: "42%"
        )
        try fixture.database.saveReadingProgress(progress, spaceID: imported.space.id)
        let annotation = Annotation(
            id: UUID().uuidString, spaceID: imported.space.id, sourceID: imported.source.id,
            snapshotID: imported.snapshot.id, kind: .note, locator: locator,
            anchorState: .current, selectedText: "Body", note: "Keep me", color: nil,
            createdAt: .now, updatedAt: .now
        )
        try fixture.database.saveAnnotation(annotation)
        try fixture.database.recordReadingHistory(ReadingHistoryEntry(
            spaceID: imported.space.id, sourceID: imported.source.id,
            snapshotID: imported.snapshot.id, locator: locator
        ))
        let previousProgress = try fixture.database.fetchReadingProgress(spaceID: imported.space.id)
        let previousHistory = try fixture.database.fetchReadingHistory(spaceID: imported.space.id)
        let previousAnnotations = try fixture.database.fetchAnnotations(spaceID: imported.space.id)
        for state in [SpaceOrganizationState.archived, .read, .reading, .inbox] {
            try fixture.database.setSpaceOrganization(state, spaceIDs: [imported.space.id])
            XCTAssertEqual(try fixture.database.fetchReadingProgress(spaceID: imported.space.id), previousProgress)
            XCTAssertEqual(try fixture.database.fetchAnnotations(spaceID: imported.space.id), previousAnnotations)
            XCTAssertEqual(try fixture.database.fetchReadingHistory(spaceID: imported.space.id), previousHistory)
            XCTAssertEqual(try fixture.database.fetchSnapshots().map(\.id), [imported.snapshot.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: imported.managedURL.path))
        }
    }

    func testOldSpacesMigrateToReadingAndExplicitImportsRemainReading() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let root = fixture.root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("Library.sqlite").path)
        try LibraryDatabase.makeMigrator().migrate(queue, upTo: "v10-complete-text-search-index")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_spaces (id, title, is_favorite, created_at, updated_at)
                VALUES ('old', 'Existing', 0, ?, ?)
                """, arguments: [Date.now, Date.now])
        }
        let migrated = try LibraryDatabase(rootURL: root)
        XCTAssertEqual(try migrated.fetchSpaces().first?.organizationState, .reading)
        let imported = try await fixture.library.importLocalSource(at: try fixture.file("direct.txt", "direct"))
        XCTAssertEqual(imported.space.organizationState, .reading)
    }

    func testRemovedCapturedSourceIsNotResurrectedByRetry() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("removed.md", "# Remove")))
        let result = try await fixture.process(receipt.id)
        _ = try fixture.database.commitRemoval(sourceID: result.imported.source.id)
        // Simulate a failed prepare after a deliberate source removal.
        try await fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE capture_jobs SET phase = 'failed' WHERE id = ?", arguments: [receipt.id])
        }
        try fixture.database.retryCapture(receipt.id)
        let attempted = await fixture.coordinator.process(receipt.id)
        XCTAssertNil(attempted)
        XCTAssertTrue(try fixture.database.fetchSources().isEmpty)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .failed)
    }

    func testLargeImportRequiresExplicitConfirmationOnRetry() async throws {
        let fixture = try CaptureFixture(storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: 5, minimumFreeCapacity: 0, capacityProvider: { _ in .max }
        ))
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("large.txt", "larger than five")))
        let failed = await fixture.coordinator.process(receipt.id)
        XCTAssertNil(failed)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.requiresLargeImportConfirmation, true)
        try fixture.database.retryCapture(receipt.id)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .failed)
        try fixture.database.retryCapture(receipt.id, confirmLargeImport: true)
        _ = try await fixture.process(receipt.id)
        XCTAssertEqual(try fixture.database.fetchSources().count, 1)
    }

    func testCapacityDropAfterCommitRollsBackSourceAndReceiptTogether() async throws {
        let capacity = CaptureCapacitySequence()
        let fixture = try CaptureFixture(storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max, minimumFreeCapacity: 10,
            capacityProvider: { _ in capacity.next() }
        ))
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("capacity.txt", "capacity")))
        let failed = await fixture.coordinator.process(receipt.id)
        XCTAssertNil(failed)
        XCTAssertTrue(try fixture.database.fetchSources().isEmpty)
        XCTAssertTrue(try fixture.database.fetchSpaces().isEmpty)
        XCTAssertNil(try fixture.database.captureJob(receipt.id)?.sourceID)
        XCTAssertEqual(try fixture.database.captureJob(receipt.id)?.phase, .failed)
    }

    func testIdenticalContentKeepsIndependentCaptureIdentities() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let input = try fixture.file("duplicate.md", "# Same bytes")
        let first = try await fixture.coordinator.receive(.local(input))
        let second = try await fixture.coordinator.receive(.local(input))
        let one = try await fixture.process(first.id)
        let two = try await fixture.process(second.id)
        XCTAssertNotEqual(one.imported.source.id, two.imported.source.id)
        XCTAssertNotEqual(one.imported.snapshot.id, two.imported.snapshot.id)
        XCTAssertNotEqual(one.imported.space.id, two.imported.space.id)
        XCTAssertEqual(one.imported.snapshot.digest, two.imported.snapshot.digest)
        XCTAssertEqual(one.imported.managedURL, two.imported.managedURL)
    }

    func testOrganizingIntoExistingSpacePreservesOriginalRecordsAndMembership() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.coordinator.receive(.local(try fixture.file("inbox.md", "# Inbox")))
        let captured = try await fixture.process(receipt.id)
        let existing = try await fixture.library.importLocalSource(at: try fixture.file("reading.md", "# Reading"))
        try fixture.database.organizeCaptures([receipt.id], intoSpaceID: existing.space.id)
        XCTAssertEqual(Set(try fixture.database.sourceIDs(in: existing.space.id)), [captured.imported.source.id, existing.source.id])
        XCTAssertEqual(try fixture.database.sourceIDs(in: captured.imported.space.id), [captured.imported.source.id])
        XCTAssertEqual(try fixture.database.fetchSpaces().first { $0.id == captured.imported.space.id }?.organizationState, .archived)
        XCTAssertEqual(try fixture.database.fetchSpaces().first { $0.id == existing.space.id }?.organizationState, .reading)
        XCTAssertEqual(try fixture.database.fetchSources().count, 2)
    }

    func testAppCaptureDoesNotStealOpenReaderAndArchiveFilterIsReversible() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.cleanUp() }
        let defaults = UserDefaults(suiteName: "CaptureTests.\(UUID().uuidString)")!
        let model = AppModel(
            libraryRootURL: fixture.root.appendingPathComponent("AppLibrary"),
            defaults: defaults, secretStore: InMemoryProviderSecretStore(), automaticBootstrap: false
        )
        await model.bootstrap()
        model.importLocalURLs([try fixture.file("active.md", "# Active")])
        try await waitFor { model.presentationDocument != nil }
        let previousSource = model.selectedSourceID
        model.captureURLs([try fixture.file("captured.md", "# Captured")])
        try await waitFor { model.captureJobs.first?.phase == .ready }
        XCTAssertEqual(model.selectedSourceID, previousSource)
        XCTAssertTrue(model.isReadingWorkspaceOpen)
        let inboxSpace = try XCTUnwrap(model.captureJobs.first?.spaceID)
        model.selectCollection(.inbox)
        XCTAssertEqual(model.visibleSpaces.map(\.id), [inboxSpace])
        model.setOrganization(.archived, for: [inboxSpace])
        XCTAssertTrue(model.visibleSpaces.isEmpty)
        model.selectCollection(.archived)
        XCTAssertEqual(model.visibleSpaces.map(\.id), [inboxSpace])
        model.setOrganization(.reading, for: [inboxSpace])
        model.selectCollection(.reading)
        XCTAssertEqual(model.visibleSpaces.count, 2)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for isolated capture state")
    }
}

private struct CaptureFixture {
    let root: URL
    let database: LibraryDatabase
    let library: ManagedLibrary
    let adapters: AdapterCoordinator
    let importer: RemoteSourceImporter
    let staging: CaptureStagingStore
    let coordinator: CaptureCoordinator
    let session: URLSession

    init(storagePolicy: LibraryStoragePolicy = LibraryStoragePolicy(
        largeImportThreshold: .max, minimumFreeCapacity: 0, capacityProvider: { _ in .max }
    )) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OneReader-Capture-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        library = try ManagedLibrary(database: database, storagePolicy: storagePolicy)
        adapters = AdapterCoordinator(database: database, registry: try AdapterRegistry.standard())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        session = URLSession(configuration: configuration)
        importer = RemoteSourceImporter(library: library, session: session, hostValidator: { _ in })
        staging = CaptureStagingStore(
            rootURL: root.appendingPathComponent("Capture"), maximumBytes: .max,
            allowsDirectories: true, capacity: { _ in .max }
        )
        coordinator = CaptureCoordinator(database: database, library: library, remoteImporter: importer, adapters: adapters, staging: staging)
    }

    func store(_ name: String) -> CaptureStagingStore {
        CaptureStagingStore(
            rootURL: root.appendingPathComponent(name), maximumBytes: .max,
            allowsDirectories: true, capacity: { _ in .max }
        )
    }
    func makeCoordinator(shared: CaptureStagingStore) -> CaptureCoordinator {
        CaptureCoordinator(database: database, library: library, remoteImporter: importer, adapters: adapters, staging: staging, sharedStaging: shared)
    }
    func file(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }
    func cleanUp() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    func process(_ id: String) async throws -> CapturePreparedResult {
        let result = await coordinator.process(id)
        return try XCTUnwrap(result)
    }
}

private final class CaptureCapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int64 {
        lock.withLock { calls += 1; return calls == 1 ? .max : 0 }
    }
}

private final class CaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var offline = true
    nonisolated(unsafe) private static var requests = 0
    static var requestCount: Int { lock.withLock { requests } }
    static func configure(offline: Bool) { lock.withLock { self.offline = offline; requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let unavailable = Self.lock.withLock { Self.requests += 1; return Self.offline }
        if unavailable {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/markdown"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("# Offline-ready snapshot\n\nGenerated fixture.".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
