import XCTest
@testable import OneReader

@MainActor
final class ReaderWorkspaceModelsTests: XCTestCase {
    func testReaderNavigationKeepsReadableDocumentsInsideAssetDirectories() {
        let readme = node(
            path: "assets/README.md",
            mediaType: "text/markdown",
            isReadable: true
        )
        let image = node(
            path: "assets/cover.png",
            mediaType: "image/png",
            isReadable: true
        )
        let font = node(
            path: "fonts/reader.woff2",
            mediaType: "font/woff2",
            isReadable: true
        )
        let directory = node(
            path: "assets",
            mediaType: "text/x-directory",
            isReadable: false,
            kind: .directory
        )

        XCTAssertEqual(
            ReaderContentNavigation.outlineNodes(from: [directory, readme, image, font]),
            [directory, readme]
        )
        XCTAssertEqual(
            ReaderContentNavigation.readableNodes(from: [directory, readme, image, font]),
            [readme]
        )
    }

    func testRevealReaderNavigationChangesTabAndPublishesARevealRequest() {
        let model = AppModel(automaticBootstrap: false)
        let initialRequest = model.readerNavigationRequestID

        model.revealReaderNavigation(.search)

        XCTAssertEqual(model.navigationTab, .search)
        XCTAssertNotEqual(model.readerNavigationRequestID, initialRequest)
    }

    private func node(
        path: String,
        mediaType: String,
        isReadable: Bool,
        kind: ContentNodeKind = .file
    ) -> ContentNode {
        let locator = Locator(
            sourceID: "source",
            snapshotID: "snapshot",
            adapterID: "adapter",
            payload: ["path": path],
            structuralPath: path
        )
        return ContentNode(
            id: locator.stableID,
            title: (path as NSString).lastPathComponent,
            kind: kind,
            locator: locator,
            depth: max(0, path.split(separator: "/").count - 1),
            order: 0,
            mediaType: mediaType,
            isReadable: isReadable
        )
    }
}
