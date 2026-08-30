import Foundation
import XCTest
@testable import OneReader

final class LocatorTests: XCTestCase {
    func testSameNativePathOnDifferentRevisionsIsNotEqual() {
        let first = Locator(
            sourceID: "github:owner/repo",
            snapshotID: "snapshot-commit-a",
            adapterID: "onereader.markdown",
            payload: ["path": "Chapter1.md", "startLine": "1", "endLine": "20"],
            structuralPath: "Chapter1.md",
            textQuote: nil,
            fingerprint: nil
        )
        let second = Locator(
            sourceID: "github:owner/repo",
            snapshotID: "snapshot-commit-b",
            adapterID: "onereader.markdown",
            payload: ["path": "Chapter1.md", "startLine": "1", "endLine": "20"],
            structuralPath: "Chapter1.md",
            textQuote: nil,
            fingerprint: nil
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.stableID, second.stableID)
    }

    func testLocatorCodableRoundTrip() throws {
        let locator = Locator(
            sourceID: "pdf:test",
            snapshotID: "snapshot-digest",
            adapterID: "onereader.pdf",
            payload: ["pageIndex": "17"],
            structuralPath: "page/17",
            textQuote: TextQuote(prefix: "before", exact: "heading", suffix: "after"),
            fingerprint: "fingerprint"
        )

        let data = try JSONEncoder().encode(locator)
        let restored = try JSONDecoder().decode(Locator.self, from: data)

        XCTAssertEqual(restored, locator)
        XCTAssertEqual(restored.pdfPageIndex, 17)
    }
}
