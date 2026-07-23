import Foundation
import XCTest
@testable import OneReader

final class LocatorTests: XCTestCase {
    func testSameNativePathOnDifferentRevisionsIsNotEqual() {
        let first = Locator(
            sourceID: "github:owner/repo",
            sourceRevision: "commit-a",
            native: .repository(path: "Chapter1.md", startLine: 1, endLine: 20),
            textAnchor: nil,
            fingerprint: nil
        )
        let second = Locator(
            sourceID: "github:owner/repo",
            sourceRevision: "commit-b",
            native: .repository(path: "Chapter1.md", startLine: 1, endLine: 20),
            textAnchor: nil,
            fingerprint: nil
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.stableID, second.stableID)
    }

    func testLocatorCodableRoundTrip() throws {
        let locator = Locator(
            sourceID: "pdf:test",
            sourceRevision: "digest",
            native: .pdf(pageIndex: 17),
            textAnchor: TextAnchor(prefix: "before", exact: "heading", suffix: "after"),
            fingerprint: "fingerprint"
        )

        let data = try JSONEncoder().encode(locator)
        let restored = try JSONDecoder().decode(Locator.self, from: data)

        XCTAssertEqual(restored, locator)
    }
}
