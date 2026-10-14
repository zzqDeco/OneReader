import Foundation
@testable import OneReader
import XCTest

final class ReleaseMetadataTests: XCTestCase {
    func testReleaseMetadataMatchesMigratedLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReader-ReleaseMetadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(rootURL: root)
        let metadata = try database.schemaMetadata()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Resources/ReleaseMetadata.plist"))
        let payload = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        for (releaseKey, databaseKey) in [
            ("DatabaseSchemaVersion", "database_schema"),
            ("AdapterSchemaVersion", "adapter_schema"),
            ("AgentRuntimeSchemaVersion", "agent_runtime_schema"),
        ] {
            let stored = try XCTUnwrap(metadata[databaseKey].flatMap(Int.init))
            XCTAssertEqual(payload[releaseKey] as? Int, stored, releaseKey)
        }
    }

    func testReleaseMetadataMatchesRuntimeSchemas() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("Resources/ReleaseMetadata.plist")
        let data = try Data(contentsOf: url)
        let payload = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(payload["ManifestSchemaVersion"] as? Int, 1)
        XCTAssertEqual(
            payload["DatabaseSchemaVersion"] as? Int,
            LibraryDatabase.schemaVersion
        )
        XCTAssertEqual(
            payload["AdapterSchemaVersion"] as? Int,
            LibraryDatabase.adapterSchemaVersion
        )
        XCTAssertEqual(
            payload["AgentRuntimeSchemaVersion"] as? Int,
            LibraryDatabase.agentRuntimeSchemaVersion
        )
    }
}
