import Foundation
import XCTest
@testable import OneReader

final class NotesExportTests: XCTestCase {
    func testPlainSourceMarkdownGolden() {
        let note = entry(id: "note-1")
        let snapshot = NotesExportSnapshot(libraryID: "library-id", entries: [note], options: NotesExportOptions(), capturedAt: Date(timeIntervalSince1970: 0))
        let expected = #"""
        # Book

        来源 ID：source\-1

        [返回索引](./index.md)

        ## 高亮 · onereader\.markdown

        - 标注 ID：note\-1
        - 所属空间：Space（space\-1）
        - 快照：snapshot\-1
        - 定位状态：current · 当前快照
        - 创建：1970-01-01T00:00:00Z
        - 更新：1970-01-01T00:00:01Z
        - 标签：

        [在本机 OneReader 查看原文](onereader://notes/v1?library=library-id&annotation=note-1&source=source-1&snapshot=snapshot-1)

        ### 摘录

        > excerpt

        ### 用户笔记

        > note

        ---
        """# + "\n"
        XCTAssertEqual(NotesMarkdownExporter.renderSource([note], snapshot: snapshot), expected)
    }

    func testDeterministicMarkdownSanitizesContentNamesAndLinks() throws {
        let entry = entry(id: "note-1", source: "source-1", title: "../Books/同名 [书]", text: "![image](https://evil.test/pixel)\n<script>bad()</script>\n```\n# header", note: "[link](file:///private/secret)")
        let second = self.entry(id: "note-2", source: "source-2", title: "../Books/同名 [书]")
        let snapshot = NotesExportSnapshot(libraryID: "library-id", entries: [second, entry], options: NotesExportOptions(), capturedAt: Date(timeIntervalSince1970: 0))
        let markdown = NotesMarkdownExporter.renderSource([entry], snapshot: snapshot)
        XCTAssertFalse(markdown.contains("![image]("))
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertFalse(markdown.contains("[link](file:"))
        XCTAssertTrue(markdown.contains("\\!\\[image\\]"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;"))
        XCTAssertTrue(markdown.contains("onereader://notes/v1?library=library-id&annotation=note-1&source=source-1&snapshot=snapshot-1"))
        XCTAssertFalse(markdown.contains("https://example.com"), "Original web URLs require opt-in")
        let name = NotesMarkdownExporter.fileName(title: entry.sourceTitle, sourceID: "source-1")
        let otherName = NotesMarkdownExporter.fileName(title: second.sourceTitle, sourceID: "source-2")
        XCTAssertNotEqual(name.lowercased(), otherName.lowercased())
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertLessThan(name.utf8.count, 200)
        let reverse = NotesExportSnapshot(libraryID: snapshot.libraryID, entries: snapshot.entries.reversed(), options: snapshot.options, capturedAt: snapshot.capturedAt)
        XCTAssertEqual(NotesMarkdownExporter.renderIndex(snapshot), NotesMarkdownExporter.renderIndex(reverse))
        let noNote = NotesExportSnapshot(libraryID: "library-id", entries: [entry], options: NotesExportOptions(includeNotes: false, includeWebURLs: true), capturedAt: snapshot.capturedAt)
        let optedIn = NotesMarkdownExporter.renderSource([entry], snapshot: noNote)
        XCTAssertFalse(optedIn.contains("### 用户笔记"))
        XCTAssertTrue(optedIn.contains("https://example.com/book"))
        XCTAssertFalse(optedIn.contains("token="))
        XCTAssertNil(NotesMarkdownExporter.safeWebURL(URL(string: "file:///tmp/private")!))
        XCTAssertNil(NotesMarkdownExporter.safeWebURL(URL(string: "https://user:pass@example.com")!))
    }

    func testAtomicNewCopiesPreserveExistingFilesAndCancelWithoutPartialDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = NotesExportSnapshot(libraryID: "library", entries: [entry(id: "a"), entry(id: "b", source: "source-2")], options: NotesExportOptions(), capturedAt: Date(timeIntervalSince1970: 0))
        let first = try await NotesMarkdownExporter.write(snapshot, to: root)
        try Data("manual edits".utf8).write(to: first.appendingPathComponent("index.md"))
        let second = try await NotesMarkdownExporter.write(snapshot, to: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("index.md"), encoding: .utf8), "manual edits")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("index.md").path))
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let worker = Task {
            try await NotesMarkdownExporter.write(snapshot, to: root, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await worker.value; XCTFail("Cancellation must prevent publication") }
        catch is CancellationError {}
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(before, after, "No partial staging or final directory survives cancellation")
    }

    func testWriteFailureDoesNotTouchExistingUserContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notDirectory = root.appendingPathComponent("manual.md")
        try Data("preserve me".utf8).write(to: notDirectory)
        let snapshot = NotesExportSnapshot(libraryID: "library", entries: [entry(id: "a")], options: NotesExportOptions(), capturedAt: .now)
        do { _ = try await NotesMarkdownExporter.write(snapshot, to: notDirectory); XCTFail("A file is not a destination directory") }
        catch { XCTAssertEqual(error as? NotesError, .invalidDestination) }
        XCTAssertEqual(try String(contentsOf: notDirectory, encoding: .utf8), "preserve me")
        let fault = DiskFullWriter()
        do {
            _ = try await NotesMarkdownExporter.write(snapshot, to: root, writeFile: fault.write)
            XCTFail("Disk-full error must be reported")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteOutOfSpace)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["manual.md"])
    }

    private func entry(id: String, source: String = "source-1", title: String = "Book", text: String = "excerpt", note: String = "note") -> NotesEntry {
        let annotation = Annotation(id: id, spaceID: "space-1", sourceID: source, snapshotID: "snapshot-1", kind: .highlight, locator: Locator(sourceID: source, snapshotID: "snapshot-1", adapterID: MarkdownAdapter.id, payload: ["startLine": "3"]), anchorState: .current, selectedText: text, note: note, color: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 1))
        return NotesEntry(annotation: annotation, sourceTitle: title, spaceTitle: "Space", sourceAvailable: true, isLatestSnapshot: true, originalWebURL: URL(string: "https://example.com/book?token=secret#fragment"), tags: [])
    }
}

private final class DiskFullWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        writes += 1
        let shouldFail = writes > 1
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
