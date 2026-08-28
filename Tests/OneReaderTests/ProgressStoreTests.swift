import Foundation
import XCTest
@testable import OneReader

final class ProgressStoreTests: XCTestCase {
    func testDefaultProgressPathDoesNotReuseLegacyArchiveInput() {
        XCTAssertEqual(ProgressStore.defaultFileURL().lastPathComponent, "progress-v2.json")
    }

    func testProgressRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("progress.json")
        let store = ProgressStore(fileURL: fileURL)

        var progress = ReadingProgress.empty
        progress.currentUnitID = "unit:test"
        progress.activeGoal = .quickOverview
        progress.units["unit:test"] = UnitProgress(
            unitID: "unit:test",
            state: .completed,
            fraction: 1,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        try await store.save(progress)
        let restored = try await store.load()

        XCTAssertEqual(restored.currentUnitID, "unit:test")
        XCTAssertEqual(restored.activeGoal, .quickOverview)
        XCTAssertEqual(restored.state(for: "unit:test"), .completed)
    }

    func testUnsupportedSchemaFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("progress.json")
        var progress = ReadingProgress.empty
        progress.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(progress).write(to: fileURL)

        let store = ProgressStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected unsupported schema error")
        } catch {
            XCTAssertEqual(error as? ProgressStoreError, .unsupportedSchema(99))
        }
    }
}
