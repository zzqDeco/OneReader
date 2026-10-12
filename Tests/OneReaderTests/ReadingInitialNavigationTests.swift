import PDFKit
import XCTest
import ZIPFoundation
@testable import OneReader

@MainActor
final class ReadingInitialNavigationTests: XCTestCase {
    func testPDFStartsAtFirstPageDespiteAlphabeticallyEarlierLastOutline() async throws {
        try await assertPDFStartsAtFirstPage(titles: ["ZZZ Cover", "Middle", "AAA Poster"])
    }

    func testPDFOutlineSlashesAndIndexNamesAreNotDirectoryPriorities() async throws {
        try await assertPDFStartsAtFirstPage(titles: ["Part/ZZZ Cover", "Middle", "index.md"])
    }

    func testPDFWithoutOutlineStartsAtFirstPage() async throws {
        try await assertPDFStartsAtFirstPage(titles: nil)
    }

    func testNestedPDFOutlineDoesNotOverrideFirstPageOrder() async throws {
        try await assertPDFStartsAtFirstPage(titles: ["ZZZ Cover", "Middle", "AAA Poster"], nestedCover: true)
    }

    func testSavedPDFPositionAndExplicitNavigationOverrideNativeFirstPage() async throws {
        let fixture = try await importFixture(pdfTitles: ["ZZZ Cover", "Middle", "AAA Poster"])
        defer { fixture.cleanUp() }
        let first = fixture.model
        let base = try XCTUnwrap(first.presentationDocument?.locator)
        let spaceID = try XCTUnwrap(first.selectedSpaceID)
        let position = Locator(
            sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: ["pageIndex": "1", "positionKind": "viewport", "viewportX": "0",
                      "viewportY": "900", "viewportScreenX": "0.2", "viewportScreenY": "0"],
            structuralPath: "page/1"
        )
        first.updateReadingPosition(ReadingPositionUpdate(
            locator: position, progressFraction: 0.5, granularity: .page,
            displayLabel: "第 2 / 3 页"
        ))
        first.closeReadingWorkspace()

        let restored = AppModel(
            libraryRootURL: fixture.libraryRoot, defaults: fixture.defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { restored.isBootstrapComplete }
        restored.openSpace(spaceID)
        try await waitUntil { restored.presentationDocument != nil }
        XCTAssertEqual(restored.presentationDocument?.locator, position)

        let explicit = Locator(
            sourceID: base.sourceID, snapshotID: base.snapshotID, adapterID: base.adapterID,
            payload: ["pageIndex": "2"], structuralPath: "page/2"
        )
        restored.openLocator(explicit)
        try await waitUntil { restored.presentationDocument?.locator == explicit }
        XCTAssertEqual(restored.presentationDocument?.locator.pdfPageIndex, 2)
        restored.closeReadingWorkspace()
    }

    func testEPUBStartsAtSpineHeadNotShallowIndexFilename() async throws {
        let fixture = try await importFixture(pdfTitles: nil, epub: true)
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.model.presentationDocument?.surface, .sanitizedWeb)
        XCTAssertEqual(fixture.model.presentationDocument?.locator.payload["href"], "OEBPS/text/deep/z.xhtml")
        XCTAssertTrue(fixture.model.presentationDocument?.content?.contains("Spine head") == true)
        XCTAssertEqual(fixture.model.contentNodes.first?.order, 0)
        fixture.model.closeReadingWorkspace()
    }

    private func assertPDFStartsAtFirstPage(titles: [String]?, nestedCover: Bool = false) async throws {
        let fixture = try await importFixture(pdfTitles: titles, nestedCover: nestedCover)
        defer { fixture.cleanUp() }
        if let titles { XCTAssertEqual(fixture.model.contentNodes.map(\.title), titles, "Regression input must retain its misleading outline") }
        if nestedCover { XCTAssertEqual(fixture.model.contentNodes.first?.depth, 1) }
        XCTAssertEqual(fixture.model.presentationDocument?.surface, .pdfKit)
        XCTAssertEqual(fixture.model.presentationDocument?.locator.pdfPageIndex, 0)
        XCTAssertEqual(fixture.model.currentPositionLocator?.pdfPageIndex, 0)
        XCTAssertEqual(fixture.model.currentProgress.sourcePositions[fixture.model.selectedSourceID ?? ""]?.locator.pdfPageIndex, 0)
        fixture.model.closeReadingWorkspace()
    }

    private func importFixture(pdfTitles: [String]?, epub: Bool = false, nestedCover: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderInitialNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent(epub ? "spine.epub" : "outline.pdf")
        if epub { try writeEPUB(to: input) } else { try writePDF(to: input, titles: pdfTitles, nestedCover: nestedCover) }
        let suite = "OneReaderInitialNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let model = AppModel(libraryRootURL: libraryRoot, defaults: defaults, secretStore: InMemoryProviderSecretStore())
        try await waitUntil { model.isBootstrapComplete }
        model.importLocalURLs([input])
        try await waitUntil { model.presentationDocument != nil && model.activePendingImportCount == 0 }
        return Fixture(model: model, root: root, libraryRoot: libraryRoot, defaults: defaults, suite: suite)
    }

    private func writePDF(to url: URL, titles: [String]?, nestedCover: Bool) throws {
        // Self-contained ASCII PDF fixture: PDFKit's writer can omit a newly
        // added outline on some SDKs. Validate the serialized input, not only
        // the mutable in-memory outline, so this regression cannot false-pass.
        let content = "BT /F1 18 Tf 40 900 Td (Generated page) Tj ET\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R \(titles == nil ? "" : "/Outlines 6 0 R") >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"
        ]
        for _ in 0..<3 {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 1600] /Resources << /Font << /F1 11 0 R >> >> /Contents 10 0 R >>")
        }
        objects.append("<< /Type /Outlines /First \(nestedCover ? 12 : 7) 0 R /Last 9 0 R /Count \(nestedCover ? 4 : 3) >>")
        for index in 0..<3 {
            let title = (titles?[index] ?? "Page \(index + 1)")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            let previous = index == 0 ? "" : "/Prev \(nestedCover && index == 1 ? 12 : 6 + index) 0 R"
            let next = index == 2 || (nestedCover && index == 0) ? "" : "/Next \(8 + index) 0 R"
            objects.append("<< /Title (\(title)) /Parent \(nestedCover && index == 0 ? 12 : 6) 0 R \(previous) \(next) /Dest [\(3 + index) 0 R /XYZ 0 1600 null] >>")
        }
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        if nestedCover { objects.append("<< /Title (Cover group) /Parent 6 0 R /First 7 0 R /Last 7 0 R /Count 1 /Next 8 0 R >>") }
        var bytes = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(written.pageCount, 3)
        if let titles { XCTAssertEqual(written.outlineRoot?.numberOfChildren, titles.count) }
    }

    private func writeEPUB(to url: URL) throws {
        let container = """
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """
        let package = """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Spine order</dc:title></metadata>
        <manifest><item id="head" href="text/deep/z.xhtml" media-type="application/xhtml+xml"/>
        <item id="index" href="index.html" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="head"/><itemref idref="index"/></spine></package>
        """
        let entries = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", package),
            ("OEBPS/text/deep/z.xhtml", "<html><head><title>Spine head</title></head><body><h1>Spine head</h1></body></html>"),
            ("OEBPS/index.html", "<html><head><title>Later index</title></head><body><h1>Later index</h1></body></html>")
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in entries {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count),
                                 compressionMethod: .none) { position, size in
                bytes.subdata(in: Int(position)..<min(Int(position) + size, bytes.count))
            }
        }
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Managed import/navigation did not finish")
    }

    private struct Fixture {
        let model: AppModel
        let root: URL
        let libraryRoot: URL
        let defaults: UserDefaults
        let suite: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
