import Foundation
import XCTest
@testable import OneReader

@MainActor
final class AppModelPersistenceSafetyTests: XCTestCase {
    func testDatabaseFailureStillLoadsCurrentProgressBeforeSaving() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var progress = ReadingProgress.empty
        progress.currentUnitID = "preserved-unit"
        try write(progress, to: fixture.progressURL)
        let store = ProgressStore(fileURL: fixture.progressURL)

        let model = AppModel(
            progressStore: store,
            libraryRootURL: fixture.invalidLibraryRoot
        )
        try await waitForBootstrap(model)

        XCTAssertEqual(model.progress.currentUnitID, "preserved-unit")
        model.changeGoal(.quickOverview)
        try await Task.sleep(for: .milliseconds(50))
        let saved = try await store.load()
        XCTAssertEqual(saved.currentUnitID, "preserved-unit")
        XCTAssertEqual(saved.activeGoal, .quickOverview)
    }

    func testUnreadableCurrentProgressIsNeverOverwrittenByEmptyState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var futureProgress = ReadingProgress.empty
        futureProgress.schemaVersion = 99
        try write(futureProgress, to: fixture.progressURL)
        let originalBytes = try Data(contentsOf: fixture.progressURL)

        let model = AppModel(
            progressStore: ProgressStore(fileURL: fixture.progressURL),
            libraryRootURL: fixture.invalidLibraryRoot
        )
        try await waitForBootstrap(model)
        model.changeGoal(.quickOverview)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(try Data(contentsOf: fixture.progressURL), originalBytes)
    }

    private func waitForBootstrap(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if model.isBootstrapComplete { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("AppModel bootstrap did not complete")
    }

    private func makeFixture() throws -> (
        root: URL,
        invalidLibraryRoot: URL,
        progressURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderAppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidLibraryRoot = root.appendingPathComponent("not-a-directory")
        try Data("file blocks directory creation".utf8).write(to: invalidLibraryRoot)
        return (
            root,
            invalidLibraryRoot,
            root.appendingPathComponent("progress-v2.json")
        )
    }

    private func write(_ progress: ReadingProgress, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(progress).write(to: url, options: .atomic)
    }
}
