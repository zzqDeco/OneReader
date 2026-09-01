import Foundation
import XCTest
import ZIPFoundation
@testable import OneReader

final class RemoteSourceImporterTests: XCTestCase {
    func testGitHubRepositoryURLParsingBelongsToRemoteSnapshotImporter() throws {
        let coordinate = try RemoteSourceImporter.parseGitHubCoordinate(
            from: URL(string: "https://github.com/xiaolai/time-as-a-friend.git")!
        )
        XCTAssertEqual(coordinate.slug, "xiaolai/time-as-a-friend")
        XCTAssertThrowsError(
            try RemoteSourceImporter.parseGitHubCoordinate(
                from: URL(string: "https://example.com/xiaolai/time-as-a-friend")!
            )
        )
    }

    override func tearDown() {
        RemoteURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testWebPageImportCreatesManagedSnapshotWithSameOriginResourceCache() async throws {
        let root = try remoteTestRoot("Web")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeRemoteSession()
        defer { session.invalidateAndCancel() }
        RemoteURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/article":
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data("""
                        <!doctype html><html><head>
                        <title>Managed Article</title>
                        <link rel="canonical" href="https://example.com/canonical">
                        </head><body>
                        <h1>Opening</h1><p>web evidence</p>
                        <img src="/cover.png"><script>promptInjection()</script>
                        </body></html>
                        """.utf8)
                )
            case "/cover.png":
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "image/png"],
                    body: Data([0x89, 0x50, 0x4e, 0x47])
                )
            default:
                return RemoteStub(status: 404, headers: [:], body: Data())
            }
        }

        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )
        let imported = try await importer.importSource(
            from: URL(string: "https://example.com/article")!
        )

        XCTAssertEqual(imported.source.originKind, .remoteURL)
        XCTAssertEqual(imported.snapshot.revisionKind, .webSnapshot)
        XCTAssertEqual(imported.source.displayName, "Managed Article")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: imported.managedURL.appendingPathComponent("index.html").path
            )
        )
        let manifestData = try Data(
            contentsOf: imported.managedURL.appendingPathComponent(WebSnapshotManifest.filename)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(WebSnapshotManifest.self, from: manifestData)
        XCTAssertEqual(manifest.canonicalURL?.absoluteString, "https://example.com/canonical")
        XCTAssertEqual(manifest.cachedResources.count, 1)
        let storedHTML = try String(
            contentsOf: imported.managedURL.appendingPathComponent("index.html"),
            encoding: .utf8
        )
        XCTAssertTrue(storedHTML.contains("resources/"))
        XCTAssertFalse(storedHTML.contains("src=\"/cover.png\""))

        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepareAndIndex(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        XCTAssertEqual(plan.primaryAdapterID, WebSnapshotAdapter.id)
        let presentation = try await coordinator.render(plan: plan)
        XCTAssertEqual(presentation.surface, .sanitizedWeb)
        XCTAssertFalse(try XCTUnwrap(presentation.content).contains("<script"))
        let hits = try await coordinator.search(
            plan: plan,
            query: "evidence"
        )
        XCTAssertEqual(hits.count, 1)
    }

    func testDirectRemoteMarkdownRoutesToMarkdownAdapter() async throws {
        let root = try remoteTestRoot("Markdown")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeRemoteSession()
        defer { session.invalidateAndCancel() }
        RemoteURLProtocol.setHandler { _ in
            RemoteStub(
                status: 200,
                headers: ["Content-Type": "text/markdown"],
                body: Data("# Remote chapter\n\nremote evidence".utf8)
            )
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )
        let imported = try await importer.importSource(
            from: URL(string: "https://example.com/chapter.md")!
        )

        XCTAssertEqual(imported.snapshot.revisionKind, .contentDigest)
        XCTAssertEqual(imported.source.displayName, "chapter.md")
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        XCTAssertEqual(plan.primaryAdapterID, MarkdownAdapter.id)
    }

    func testOversizedWebResourceIsDroppedBeforeSnapshotCommit() async throws {
        let root = try remoteTestRoot("OversizedResource")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeRemoteSession()
        defer { session.invalidateAndCancel() }
        RemoteURLProtocol.setHandler { request in
            if request.url?.path == "/large.png" {
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "image/png"],
                    body: Data(repeating: 0x41, count: 5 * 1_024 * 1_024 + 1)
                )
            }
            return RemoteStub(
                status: 200,
                headers: ["Content-Type": "text/html"],
                body: Data("<title>Bounded</title><img src=\"/large.png\"><p>text remains</p>".utf8)
            )
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )

        let imported = try await importer.importWebPage(
            from: URL(string: "https://example.com/article")!
        )

        let data = try Data(
            contentsOf: imported.managedURL.appendingPathComponent(WebSnapshotManifest.filename)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(WebSnapshotManifest.self, from: data)
        XCTAssertTrue(manifest.cachedResources.isEmpty)
        XCTAssertTrue(
            try String(
                contentsOf: imported.managedURL.appendingPathComponent("index.html"),
                encoding: .utf8
            ).contains("text remains")
        )
    }

    func testPublicGitHubImportPinsExactCommitAndMaterializesRepositoryTree() async throws {
        let root = try remoteTestRoot("GitHub")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveData = try githubArchiveData(root: root)
        let commit = String(repeating: "a", count: 40)
        let session = makeRemoteSession()
        defer { session.invalidateAndCancel() }
        RemoteURLProtocol.setHandler { request in
            guard let url = request.url else {
                return RemoteStub(status: 400, headers: [:], body: Data())
            }
            if url.host == "api.github.com", url.path == "/repos/xiaolai/time-as-a-friend" {
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"name":"time-as-a-friend","default_branch":"master"}"#.utf8)
                )
            }
            if url.host == "api.github.com",
               url.path == "/repos/xiaolai/time-as-a-friend/commits/master" {
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data("{\"sha\":\"\(commit)\"}".utf8)
                )
            }
            if url.host == "codeload.github.com" {
                return RemoteStub(
                    status: 200,
                    headers: ["Content-Type": "application/zip"],
                    body: archiveData
                )
            }
            return RemoteStub(status: 404, headers: [:], body: Data())
        }

        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )
        let imported = try await importer.importSource(
            from: URL(string: "https://github.com/xiaolai/time-as-a-friend/tree/master")!
        )

        XCTAssertEqual(imported.source.originKind, .githubRepository)
        XCTAssertEqual(imported.snapshot.revisionKind, .gitCommit)
        XCTAssertEqual(imported.snapshot.revision, commit)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: imported.managedURL.appendingPathComponent("README.md").path
            )
        )
        let coordinator = try AdapterCoordinator.standard(database: database)
        let plan = try await coordinator.prepare(
            sourceID: imported.source.id,
            snapshotID: imported.snapshot.id
        )
        XCTAssertEqual(plan.primaryAdapterID, DirectoryAdapter.id)
        XCTAssertTrue(plan.auxiliaryAdapterIDs.contains(MarkdownAdapter.id))
    }

    func testRedirectDelegateAcceptsOnlyHTTPSAllowedHosts() throws {
        let delegate = OriginBoundRedirectDelegate(allowedHosts: ["example.com"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://example.com/start")!)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://example.com/start")!,
                statusCode: 301,
                httpVersion: nil,
                headerFields: nil
            )
        )

        var accepted: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.com/final")!),
            completionHandler: { accepted = $0 }
        )
        XCTAssertEqual(accepted?.url?.absoluteString, "https://example.com/final")

        var rejected: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://evil.example/final")!),
            completionHandler: { rejected = $0 }
        )
        XCTAssertNil(rejected)
        XCTAssertEqual(delegate.rejectedURL?.host, "evil.example")
    }

    func testCancellingRemoteImportCommitsNoSource() async throws {
        let root = try remoteTestRoot("Cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        BlockingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )

        let task = Task {
            try await importer.importSource(
                from: URL(string: "https://example.com/slow.md")!
            )
        }
        for _ in 0..<100 where !BlockingURLProtocol.didStart {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(BlockingURLProtocol.didStart)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected normalized cancellation.
        }

        for _ in 0..<200 where !BlockingURLProtocol.didStop {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(BlockingURLProtocol.didStop)
        XCTAssertTrue(try database.fetchSources().isEmpty)
    }

    func testPrivateNetworkAndPlainHTTPURLsAreRejectedBeforeFetch() async throws {
        let root = try remoteTestRoot("NetworkBoundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeRemoteSession()
        defer { session.invalidateAndCancel() }
        RemoteURLProtocol.setHandler { _ in
            XCTFail("Rejected URL must not reach URLSession")
            return RemoteStub(status: 500, headers: [:], body: Data())
        }
        let database = try LibraryDatabase(rootURL: root.appendingPathComponent("Library"))
        let library = try ManagedLibrary(database: database, storagePolicy: remoteStoragePolicy)
        let importer = RemoteSourceImporter(library: library, session: session)

        do {
            _ = try await importer.importSource(
                from: URL(string: "https://127.0.0.1/private")!
            )
            XCTFail("Expected private host rejection")
        } catch let error as RemoteSourceError {
            XCTAssertEqual(error, .unsafeHost("127.0.0.1"))
        }

        let noDNSImporter = RemoteSourceImporter(
            library: library,
            session: session,
            hostValidator: { _ in }
        )
        do {
            _ = try await noDNSImporter.importSource(
                from: URL(string: "http://example.com/plaintext")!
            )
            XCTFail("Expected HTTPS-only rejection")
        } catch let error as RemoteSourceError {
            XCTAssertEqual(error, .unsupportedScheme("http"))
        }
        XCTAssertTrue(try database.fetchSources().isEmpty)
    }

    func testHostValidatorRejectsNonPublicAddressRanges() throws {
        for host in [
            "0.0.0.0",
            "10.0.0.1",
            "127.0.0.1",
            "169.254.169.254",
            "172.16.0.1",
            "192.168.1.1",
            "::1",
            "fc00::1",
            "fe80::1",
            "64:ff9b::a00:1",
            "2001:0000::1",
            "2002:0a00:0001::1",
        ] {
            XCTAssertThrowsError(try RemoteHostValidator.validate(host), host)
        }
        XCTAssertNoThrow(try RemoteHostValidator.validate("93.184.216.34"))
    }
}

private struct RemoteStub {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class RemoteURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> RemoteStub)?
    private static let lock = NSLock()

    static func setHandler(_ newHandler: ((URLRequest) throws -> RemoteStub)?) {
        lock.withLock { handler = newHandler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let responseProvider = try XCTUnwrap(Self.lock.withLock { Self.handler })
            let stub = try responseProvider(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: stub.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class BlockingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var stopped = false
    private static let stateLock = NSLock()
    private var pendingResponse: DispatchWorkItem?

    static var didStart: Bool { stateLock.withLock { started } }
    static var didStop: Bool { stateLock.withLock { stopped } }

    static func reset() {
        stateLock.withLock {
            started = false
            stopped = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.withLock { Self.started = true }
        let responseWork = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingResponse!.isCancelled,
                  let url = self.request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/markdown"]
                  ) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("# late".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pendingResponse = responseWork
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: responseWork)
    }

    override func stopLoading() {
        pendingResponse?.cancel()
        Self.stateLock.withLock { Self.stopped = true }
    }
}

private func makeRemoteSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func remoteTestRoot(_ suffix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "OneReader-Remote-\(suffix)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func githubArchiveData(root: URL) throws -> Data {
    let archiveURL = root.appendingPathComponent("fixture-github.zip")
    let archive = try Archive(url: archiveURL, accessMode: .create)
    for (path, body) in [
        ("time-as-a-friend-aaaaaaaa/README.md", "# Time as a Friend\n\nEvidence."),
        ("time-as-a-friend-aaaaaaaa/Chapter0.md", "# Chapter 0"),
    ] {
        let data = Data(body.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let lower = Int(position)
                let upper = min(lower + size, data.count)
                guard lower < upper else { return Data() }
                return data.subdata(in: lower..<upper)
            }
        )
    }
    return try Data(contentsOf: archiveURL)
}

private let remoteStoragePolicy = LibraryStoragePolicy(
    largeImportThreshold: .max,
    minimumFreeCapacity: 0,
    capacityProvider: { _ in .max }
)
