import CryptoKit
import Foundation
import XCTest
import ZIPFoundation
@testable import OneReader

final class EPUBAdapterSecurityTests: XCTestCase {
    func testEPUBImplementsFullContractAndSanitizesSpineHTML() async throws {
        let fixture = try makeEPUBFixture()
        defer { fixture.remove() }
        let adapter = EPUBAdapter()

        let probe = try await adapter.probe(fixture.context)
        XCTAssertEqual(probe?.adapterID, EPUBAdapter.id)
        try await adapter.verifyRevision(in: fixture.context)
        let nodes = try await adapter.listContent(
            in: fixture.context,
            under: nil,
            limit: 20
        )
        XCTAssertEqual(nodes.map(\.title), ["First chapter"])
        XCTAssertEqual(nodes.first?.locator.payload["spineIndex"], "0")

        let observation = try await adapter.readFragment(
            in: fixture.context,
            at: try XCTUnwrap(nodes.first?.locator),
            maxCharacters: 10_000
        )
        XCTAssertTrue(observation.content.contains("EPUB evidence"))
        XCTAssertFalse(observation.content.contains("promptInjection"))
        XCTAssertNotNil(observation.contentReference)
        let hits = try await adapter.searchContent(
            in: fixture.context,
            query: "evidence",
            limit: 20
        )
        XCTAssertEqual(hits.count, 1)
        let presentation = try await adapter.presentation(
            in: fixture.context,
            at: nodes.first?.locator
        )
        XCTAssertEqual(presentation.surface, .sanitizedWeb)
        let presentationHTML = try XCTUnwrap(presentation.content)
        XCTAssertFalse(presentationHTML.contains("<script"))
        XCTAssertTrue(
            presentationHTML.contains("onereader-content:/OEBPS/images/cover.png"),
            presentationHTML
        )
        XCTAssertEqual(
            presentation.baseURL,
            fixture.context.derivedRootURL.appendingPathComponent("epub/epub-snapshot")
        )
        let resolution = try await adapter.resolve(
            try XCTUnwrap(nodes.first?.locator),
            in: fixture.context
        )
        XCTAssertEqual(resolution.state, .current)
    }

    func testSecureExtractorRejectsTraversal() throws {
        let root = try makeRoot("OneReader-EPUB-Traversal")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("bad.zip")
        try createArchive(
            at: archiveURL,
            entries: [("../escape.txt", .file, Data("escape".utf8), .none)]
        )

        XCTAssertThrowsError(
            try SecureArchiveExtractor.extract(
                archiveURL: archiveURL,
                to: root.appendingPathComponent("out"),
                policy: .epub
            )
        ) { error in
            guard case AdapterError.unsafeArchivePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("escape.txt").path
            )
        )
    }

    func testSecureExtractorRejectsSymlink() throws {
        let root = try makeRoot("OneReader-EPUB-Symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("bad.zip")
        try createArchive(
            at: archiveURL,
            entries: [("link", .symlink, Data("../outside".utf8), .none)]
        )

        XCTAssertThrowsError(
            try SecureArchiveExtractor.extract(
                archiveURL: archiveURL,
                to: root.appendingPathComponent("out"),
                policy: .epub
            )
        ) { error in
            guard case AdapterError.archiveSymlink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureExtractorRejectsExpansionBomb() throws {
        let root = try makeRoot("OneReader-EPUB-Bomb")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("bomb.zip")
        try createArchive(
            at: archiveURL,
            entries: [("large.txt", .file, Data(repeating: 65, count: 20_000), .deflate)]
        )

        XCTAssertThrowsError(
            try SecureArchiveExtractor.extract(
                archiveURL: archiveURL,
                to: root.appendingPathComponent("out"),
                policy: ArchiveExtractionPolicy(
                    maximumExpandedBytes: 1_000,
                    expansionRatio: 10
                )
            )
        ) { error in
            guard case AdapterError.archiveExpansionLimit = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureExtractorCountsActualBytesWhenZIPMetadataLies() throws {
        let root = try makeRoot("OneReader-EPUB-MetadataBomb")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("metadata-bomb.zip")
        try createArchive(
            at: archiveURL,
            entries: [("large.txt", .file, Data(repeating: 65, count: 20_000), .deflate)]
        )
        try falsifyUncompressedSize(in: archiveURL, value: 1)
        let output = root.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(
            try SecureArchiveExtractor.extract(
                archiveURL: archiveURL,
                to: output,
                policy: ArchiveExtractionPolicy(
                    maximumExpandedBytes: 1_000,
                    expansionRatio: 100
                )
            )
        ) { error in
            guard case let AdapterError.archiveExpansionLimit(limit, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 1_000)
            XCTAssertGreaterThan(actual, limit)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("large.txt").path
            )
        )
    }

    func testSecureExtractorRejectsCaseCollidingPaths() throws {
        let root = try makeRoot("OneReader-EPUB-Collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("collision.zip")
        try createArchive(
            at: archiveURL,
            entries: [
                ("OEBPS/Chapter.xhtml", .file, Data("first".utf8), .none),
                ("OEBPS/chapter.xhtml", .file, Data("second".utf8), .none),
            ]
        )

        XCTAssertThrowsError(
            try SecureArchiveExtractor.extract(
                archiveURL: archiveURL,
                to: root.appendingPathComponent("out"),
                policy: .epub
            )
        ) { error in
            guard case AdapterError.unsafeArchivePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private struct EPUBFixture {
    let root: URL
    let context: AdapterContext

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeEPUBFixture() throws -> EPUBFixture {
    let root = try makeRoot("OneReader-EPUB")
    let epubURL = root.appendingPathComponent("fixture.epub")
    let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Fixture Book</dc:title>
          </metadata>
          <manifest>
            <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
    let chapter = """
        <!doctype html><html><head><title>First chapter</title></head><body>
        <h1>First chapter</h1><p>EPUB evidence lives here.</p>
        <img src="../images/cover.png">
        <script>promptInjection()</script>
        </body></html>
        """
    try createArchive(
        at: epubURL,
        entries: [
            ("mimetype", .file, Data("application/epub+zip".utf8), .none),
            ("META-INF/container.xml", .file, Data(container.utf8), .deflate),
            ("OEBPS/content.opf", .file, Data(package.utf8), .deflate),
            ("OEBPS/text/chapter.xhtml", .file, Data(chapter.utf8), .deflate),
            ("OEBPS/images/cover.png", .file, Data([0x89, 0x50, 0x4e, 0x47]), .none),
        ]
    )
    let data = try Data(contentsOf: epubURL)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let source = Source(
        id: "epub-source",
        displayName: "fixture.epub",
        originKind: .localFile,
        originURL: epubURL,
        managedState: .ready,
        latestSnapshotID: "epub-snapshot"
    )
    let snapshot = SourceSnapshot(
        id: "epub-snapshot",
        sourceID: source.id,
        revision: digest,
        revisionKind: .contentDigest,
        digest: digest,
        observedAt: .now,
        origin: epubURL,
        managedRelativePath: nil,
        byteCount: Int64(data.count)
    )
    let derived = root.appendingPathComponent("Derived", isDirectory: true)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    return EPUBFixture(
        root: root,
        context: AdapterContext(
            source: source,
            snapshot: snapshot,
            managedURL: epubURL,
            derivedRootURL: derived,
            declaredMediaType: "application/epub+zip"
        )
    )
}

private func createArchive(
    at url: URL,
    entries: [(path: String, type: Entry.EntryType, data: Data, compression: CompressionMethod)]
) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for entry in entries {
        try archive.addEntry(
            with: entry.path,
            type: entry.type,
            uncompressedSize: Int64(entry.data.count),
            compressionMethod: entry.compression,
            provider: { position, size in
                let lower = Int(position)
                let upper = min(lower + size, entry.data.count)
                guard lower < upper else { return Data() }
                return entry.data.subdata(in: lower..<upper)
            }
        )
    }
}

private func falsifyUncompressedSize(in archiveURL: URL, value: UInt32) throws {
    var bytes = try Data(contentsOf: archiveURL)
    let signatures: [(Data, Int)] = [
        (Data([0x50, 0x4b, 0x03, 0x04]), 22),
        (Data([0x50, 0x4b, 0x01, 0x02]), 24),
    ]
    for (signature, fieldOffset) in signatures {
        let signatureRange = try XCTUnwrap(bytes.range(of: signature))
        let offset = signatureRange.lowerBound + fieldOffset
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { replacement in
            bytes.replaceSubrange(offset..<(offset + 4), with: replacement)
        }
    }
    try bytes.write(to: archiveURL, options: .atomic)
}

private func makeRoot(_ prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
