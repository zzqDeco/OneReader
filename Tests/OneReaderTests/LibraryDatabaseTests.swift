import Foundation
import XCTest
@testable import OneReader

final class LibraryDatabaseTests: XCTestCase {
    func testInitializesVersionedSchemaInWALMode() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(rootURL: root)

        XCTAssertEqual(try database.journalMode().lowercased(), "wal")
        XCTAssertEqual(
            try database.schemaMetadata(),
            [
                "adapter_schema": "1",
                "agent_runtime_schema": "1",
                "database_schema": "1",
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.sourcesURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.snapshotsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.derivedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.artifactsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.layout.databaseURL.path))
    }

    func testLegacyProgressIsBackedUpWithoutBindingToNewObjects() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let legacyURL = root.appendingPathComponent("progress-v1.json")
        try Data("{\"schemaVersion\":1}".utf8).write(to: legacyURL, options: .atomic)

        let database = try LibraryDatabase(rootURL: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let manifests = try database.migrationManifest(kind: "legacy-progress-v1")
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(manifests[0].source, "progress-v1.json")
        let destination = try XCTUnwrap(manifests[0].destination)
        let backupURL = try database.layout.url(forRelativePath: destination)
        XCTAssertEqual(try Data(contentsOf: backupURL), Data("{\"schemaVersion\":1}".utf8))
        let detail = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifests[0].detailJSON) as? [String: Any]
        )
        XCTAssertEqual(detail["boundToNewObjects"] as? Bool, false)
        XCTAssertTrue(try database.fetchSources().isEmpty)
        XCTAssertTrue(try database.fetchSpaces().isEmpty)
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return url
    }
}
