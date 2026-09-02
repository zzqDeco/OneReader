import Foundation
@testable import OneReader
import XCTest

final class ReadOnlyContentResourceTests: XCTestCase {
    func testAllowedResourceStreamsInBoundedChunks() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bytes = Data("body { color: teal; }".utf8)
        let file = fixture.root.appendingPathComponent("reader.css")
        try bytes.write(to: file)
        let loader = ReadOnlyContentResourceLoader(rootURL: fixture.root)
        let resource = try loader.resolve(
            requestURL: URL(string: "onereader-content://snapshot/reader.css")!
        )
        var received = Data()
        var chunkSizes: [Int] = []

        try loader.stream(
            resource,
            chunkBytes: 4,
            isCancelled: { false },
            receive: { chunk in
                chunkSizes.append(chunk.count)
                received.append(chunk)
            }
        )

        XCTAssertEqual(received, bytes)
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= 4 })
        XCTAssertGreaterThan(chunkSizes.count, 1)
    }

    func testOversizedUnsupportedAndSymlinkResourcesAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let large = fixture.root.appendingPathComponent("large.png")
        try Data(repeating: 1, count: 9).write(to: large)
        let unsupported = fixture.root.appendingPathComponent("payload.bin")
        try Data([1, 2, 3]).write(to: unsupported)
        let outside = fixture.parent.appendingPathComponent("outside.css")
        try Data("secret".utf8).write(to: outside)
        let link = fixture.root.appendingPathComponent("linked.css")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let loader = ReadOnlyContentResourceLoader(
            rootURL: fixture.root,
            maximumResourceBytes: 8
        )

        XCTAssertThrowsError(
            try loader.resolve(requestURL: URL(string: "onereader-content://s/large.png")!)
        ) { error in
            XCTAssertEqual(error as? ReadOnlyContentResourceError, .resourceTooLarge)
        }
        XCTAssertThrowsError(
            try loader.resolve(requestURL: URL(string: "onereader-content://s/payload.bin")!)
        ) { error in
            XCTAssertEqual(error as? ReadOnlyContentResourceError, .unsupportedMediaType)
        }
        XCTAssertThrowsError(
            try loader.resolve(requestURL: URL(string: "onereader-content://s/linked.css")!)
        ) { error in
            XCTAssertEqual(error as? ReadOnlyContentResourceError, .symbolicLink)
        }
    }

    func testStreamingStopsBeforeAnotherChunkAfterCancellation() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("reader.css")
        try Data(repeating: 7, count: 32).write(to: file)
        let loader = ReadOnlyContentResourceLoader(rootURL: fixture.root)
        let resource = try loader.resolve(
            requestURL: URL(string: "onereader-content://snapshot/reader.css")!
        )
        var cancelled = false
        var chunks = 0

        XCTAssertThrowsError(
            try loader.stream(
                resource,
                chunkBytes: 8,
                isCancelled: { cancelled },
                receive: { _ in
                    chunks += 1
                    cancelled = true
                }
            )
        ) { error in
            XCTAssertEqual(error as? ReadOnlyContentResourceError, .cancelled)
        }
        XCTAssertEqual(chunks, 1)
    }

    func testSchemeLifecycleSerializesStopAgainstResponseChunkAndFinishCallbacks() {
        for phase in ["response", "chunk", "finish"] {
            let lifecycle = ReadOnlySchemeTaskLifecycle()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let callbackReturned = DispatchSemaphore(value: 0)
            let stopReturned = DispatchSemaphore(value: 0)

            DispatchQueue.global().async {
                let callback = {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                if phase == "finish" {
                    _ = lifecycle.finishIfActive(callback)
                } else {
                    _ = lifecycle.performIfActive(callback)
                }
                callbackReturned.signal()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, phase)
            DispatchQueue.global().async {
                lifecycle.stop()
                stopReturned.signal()
            }
            XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut, phase)
            release.signal()
            XCTAssertEqual(callbackReturned.wait(timeout: .now() + 2), .success, phase)
            XCTAssertEqual(stopReturned.wait(timeout: .now() + 2), .success, phase)
            XCTAssertFalse(lifecycle.performIfActive {
                XCTFail("\(phase) callback ran after stop returned")
            })
            XCTAssertFalse(lifecycle.finishIfActive {
                XCTFail("\(phase) terminal callback ran after stop returned")
            })
        }
    }

    private func makeFixture() throws -> ResourceFixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReaderResourceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return ResourceFixture(parent: parent, root: root)
    }
}

private struct ResourceFixture {
    let parent: URL
    let root: URL

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}
