import Foundation
@testable import OneReader
import XCTest

final class ReleaseMetadataTests: XCTestCase {
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
