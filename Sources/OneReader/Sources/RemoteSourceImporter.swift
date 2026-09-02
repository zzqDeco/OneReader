import Darwin
import Foundation
import SwiftSoup
import UniformTypeIdentifiers

enum RemoteSourceError: LocalizedError, Equatable {
    case unsupportedScheme(String)
    case unsafeHost(String)
    case invalidResponse
    case httpStatus(Int)
    case redirectRejected(String)
    case payloadTooLarge(limit: Int64, actual: Int64)
    case unsupportedMediaType(String)
    case invalidGitHubMetadata
    case invalidGitHubCommit
    case invalidGitHubArchive

    var errorDescription: String? {
        switch self {
        case let .unsupportedScheme(scheme):
            "不支持的 URL scheme：\(scheme)。"
        case let .unsafeHost(host):
            "为防止读取本机或私网服务，已拒绝远程主机：\(host)。"
        case .invalidResponse:
            "远程来源返回了无法识别的响应。"
        case let .httpStatus(status):
            "远程来源请求失败（HTTP \(status)）。"
        case let .redirectRejected(url):
            "为保护来源边界，已拒绝跨来源重定向：\(url)。"
        case let .payloadTooLarge(limit, actual):
            "远程内容超过下载上限：\(actual) / \(limit) 字节。"
        case let .unsupportedMediaType(mediaType):
            "网页 URL 返回了不支持的媒体类型：\(mediaType)。"
        case .invalidGitHubMetadata:
            "GitHub 仓库元数据无法解析。"
        case .invalidGitHubCommit:
            "GitHub 没有返回可固定的 commit SHA。"
        case .invalidGitHubArchive:
            "GitHub archive 不包含可导入的仓库目录。"
        }
    }
}

struct GitHubRepositoryCoordinate: Codable, Hashable, Sendable {
    let owner: String
    let repository: String

    var slug: String { "\(owner)/\(repository)" }
}

struct WebSnapshotManifest: Codable, Hashable, Sendable {
    static let filename = ".onereader-web-snapshot.json"
    static let schemaVersion = 1

    let schemaVersion: Int
    let requestedURL: URL
    let finalURL: URL
    let canonicalURL: URL?
    let title: String
    let fetchedAt: Date
    let cachedResources: [String: URL]
}

actor RemoteSourceImporter {
    private let library: ManagedLibrary
    private let session: URLSession
    private let fileManager: FileManager
    private let hostValidator: @Sendable (String) throws -> Void

    init(
        library: ManagedLibrary,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        hostValidator: @escaping @Sendable (String) throws -> Void = RemoteHostValidator.validate
    ) {
        self.library = library
        self.session = session
        self.fileManager = fileManager
        self.hostValidator = hostValidator
    }

    func importSource(
        from url: URL,
        intoSpaceID spaceID: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedImportResult {
        if Self.isGitHubRepositoryURL(url) {
            return try await importGitHubRepository(
                from: url,
                intoSpaceID: spaceID,
                allowLargeImport: allowLargeImport
            )
        }
        return try await importRemoteURL(
            from: url,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport,
            requiresHTML: false
        )
    }

    func importWebPage(
        from requestedURL: URL,
        intoSpaceID spaceID: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedImportResult {
        try await importRemoteURL(
            from: requestedURL,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport,
            requiresHTML: true
        )
    }

    func stageRefresh(
        source: Source,
        allowLargeImport: Bool = false
    ) async throws -> ManagedRefreshCandidate {
        guard let originURL = source.originURL else {
            throw LibraryStorageError.unsupportedSource("远程来源缺少原始 URL")
        }
        if source.originKind == .githubRepository {
            return try await stageGitHubRefresh(
                sourceID: source.id,
                repositoryURL: originURL,
                allowLargeImport: allowLargeImport
            )
        }
        guard source.originKind == .remoteURL else {
            throw LibraryStorageError.unsupportedSource(originURL.absoluteString)
        }
        return try await stageRemoteURLRefresh(
            sourceID: source.id,
            requestedURL: originURL,
            allowLargeImport: allowLargeImport
        )
    }

    private func stageRemoteURLRefresh(
        sourceID: String,
        requestedURL: URL,
        allowLargeImport: Bool
    ) async throws -> ManagedRefreshCandidate {
        try Self.validateWebURL(requestedURL)
        guard let requestedHost = requestedURL.host else {
            throw RemoteSourceError.invalidResponse
        }
        try hostValidator(requestedHost)
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "OneReader-Remote-Refresh-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let downloadedURL = temporaryRoot.appendingPathComponent("downloaded")
        let response = try await download(
            requestedURL,
            to: downloadedURL,
            allowedHosts: Set([requestedURL.host?.lowercased()].compactMap { $0 }),
            maximumBytes: 4 * 1_024 * 1_024 * 1_024,
            accept: "text/html,application/xhtml+xml;q=0.9,application/pdf,application/epub+zip,text/markdown,text/plain,*/*;q=0.1"
        )
        let mediaType = response.mimeType?.lowercased() ?? "application/octet-stream"
        let isHTML = mediaType == "text/html" || mediaType == "application/xhtml+xml"
        if !isHTML {
            return try await library.stageFetchedRefresh(
                sourceID: sourceID,
                at: downloadedURL,
                revisionKind: .contentDigest,
                allowLargeImport: allowLargeImport
            )
        }

        let htmlData = try Data(contentsOf: downloadedURL, options: [.mappedIfSafe])
        guard htmlData.count <= 25 * 1_024 * 1_024 else {
            throw RemoteSourceError.payloadTooLarge(
                limit: 25 * 1_024 * 1_024,
                actual: Int64(htmlData.count)
            )
        }
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw RemoteSourceError.invalidResponse
        }
        let finalURL = response.url ?? requestedURL
        let snapshotRoot = temporaryRoot.appendingPathComponent("web-snapshot", isDirectory: true)
        try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        _ = try await materializeWebSnapshot(
            html: html,
            requestedURL: requestedURL,
            finalURL: finalURL,
            at: snapshotRoot
        )
        return try await library.stageFetchedRefresh(
            sourceID: sourceID,
            at: snapshotRoot,
            revisionKind: .webSnapshot,
            allowLargeImport: allowLargeImport
        )
    }

    private func importRemoteURL(
        from requestedURL: URL,
        intoSpaceID spaceID: String?,
        allowLargeImport: Bool,
        requiresHTML: Bool
    ) async throws -> ManagedImportResult {
        try Self.validateWebURL(requestedURL)
        guard let requestedHost = requestedURL.host else {
            throw RemoteSourceError.invalidResponse
        }
        try hostValidator(requestedHost)
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "OneReader-Remote-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let downloadedURL = temporaryRoot.appendingPathComponent("downloaded")
        let response = try await download(
            requestedURL,
            to: downloadedURL,
            allowedHosts: Set([requestedURL.host?.lowercased()].compactMap { $0 }),
            maximumBytes: 4 * 1_024 * 1_024 * 1_024,
            accept: "text/html,application/xhtml+xml;q=0.9,application/pdf,application/epub+zip,text/markdown,text/plain,*/*;q=0.1"
        )
        let mediaType = response.mimeType?.lowercased() ?? "application/octet-stream"
        let isHTML = mediaType == "text/html" || mediaType == "application/xhtml+xml"
        if requiresHTML && !isHTML {
            throw RemoteSourceError.unsupportedMediaType(mediaType)
        }
        guard isHTML else {
            let displayName = Self.remoteFilename(
                response: response,
                requestedURL: requestedURL
            )
            return try await library.importFetchedSource(
                at: downloadedURL,
                displayName: displayName,
                originKind: .remoteURL,
                originURL: requestedURL,
                revisionKind: .contentDigest,
                revision: nil,
                intoSpaceID: spaceID,
                allowLargeImport: allowLargeImport
            )
        }

        let htmlData = try Data(contentsOf: downloadedURL, options: [.mappedIfSafe])
        guard htmlData.count <= 25 * 1_024 * 1_024 else {
            throw RemoteSourceError.payloadTooLarge(
                limit: 25 * 1_024 * 1_024,
                actual: Int64(htmlData.count)
            )
        }
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw RemoteSourceError.invalidResponse
        }
        let finalURL = response.url ?? requestedURL
        let snapshotRoot = temporaryRoot.appendingPathComponent("web-snapshot", isDirectory: true)
        try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let snapshot = try await materializeWebSnapshot(
            html: html,
            requestedURL: requestedURL,
            finalURL: finalURL,
            at: snapshotRoot
        )
        return try await library.importFetchedSource(
            at: snapshotRoot,
            displayName: snapshot.title,
            originKind: .remoteURL,
            originURL: requestedURL,
            revisionKind: .webSnapshot,
            revision: nil,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport
        )
    }

    func importGitHubRepository(
        from repositoryURL: URL,
        intoSpaceID spaceID: String? = nil,
        allowLargeImport: Bool = false
    ) async throws -> ManagedImportResult {
        let coordinate = try Self.parseGitHubCoordinate(from: repositoryURL)
        let allowedAPIHosts: Set<String> = ["api.github.com"]
        let metadataPayload = try await fetchData(
            Self.githubAPIURL(["repos", coordinate.owner, coordinate.repository]),
            allowedHosts: allowedAPIHosts,
            maximumBytes: 2 * 1_024 * 1_024,
            accept: "application/vnd.github+json"
        )
        guard let metadata = try? JSONDecoder().decode(
            GitHubSnapshotMetadata.self,
            from: metadataPayload.data
        ) else {
            throw RemoteSourceError.invalidGitHubMetadata
        }
        let commitPayload = try await fetchData(
            Self.githubAPIURL([
                "repos", coordinate.owner, coordinate.repository,
                "commits", metadata.defaultBranch,
            ]),
            allowedHosts: allowedAPIHosts,
            maximumBytes: 2 * 1_024 * 1_024,
            accept: "application/vnd.github+json"
        )
        guard let commit = try? JSONDecoder().decode(
            GitHubSnapshotCommit.self,
            from: commitPayload.data
        ), Self.isFullGitSHA(commit.sha) else {
            throw RemoteSourceError.invalidGitHubCommit
        }

        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "OneReader-GitHub-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let archiveURL = temporaryRoot.appendingPathComponent("repository.zip")
        let extractedURL = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let codeloadURL = Self.githubArchiveURL(coordinate: coordinate, revision: commit.sha)
        try await download(
            codeloadURL,
            to: archiveURL,
            allowedHosts: ["codeload.github.com"],
            maximumBytes: 1 * 1_024 * 1_024 * 1_024,
            accept: "application/zip"
        )
        try SecureArchiveExtractor.extract(
            archiveURL: archiveURL,
            to: extractedURL,
            policy: .github,
            fileManager: fileManager
        )
        let repositoryRoot = try extractedRepositoryRoot(at: extractedURL)
        return try await library.importFetchedSource(
            at: repositoryRoot,
            displayName: metadata.name,
            originKind: .githubRepository,
            originURL: repositoryURL,
            revisionKind: .gitCommit,
            revision: commit.sha,
            intoSpaceID: spaceID,
            allowLargeImport: allowLargeImport
        )
    }

    private func stageGitHubRefresh(
        sourceID: String,
        repositoryURL: URL,
        allowLargeImport: Bool
    ) async throws -> ManagedRefreshCandidate {
        let coordinate = try Self.parseGitHubCoordinate(from: repositoryURL)
        let allowedAPIHosts: Set<String> = ["api.github.com"]
        let metadataPayload = try await fetchData(
            Self.githubAPIURL(["repos", coordinate.owner, coordinate.repository]),
            allowedHosts: allowedAPIHosts,
            maximumBytes: 2 * 1_024 * 1_024,
            accept: "application/vnd.github+json"
        )
        guard let metadata = try? JSONDecoder().decode(
            GitHubSnapshotMetadata.self,
            from: metadataPayload.data
        ) else {
            throw RemoteSourceError.invalidGitHubMetadata
        }
        let commitPayload = try await fetchData(
            Self.githubAPIURL([
                "repos", coordinate.owner, coordinate.repository,
                "commits", metadata.defaultBranch,
            ]),
            allowedHosts: allowedAPIHosts,
            maximumBytes: 2 * 1_024 * 1_024,
            accept: "application/vnd.github+json"
        )
        guard let commit = try? JSONDecoder().decode(
            GitHubSnapshotCommit.self,
            from: commitPayload.data
        ), Self.isFullGitSHA(commit.sha) else {
            throw RemoteSourceError.invalidGitHubCommit
        }

        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "OneReader-GitHub-Refresh-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let archiveURL = temporaryRoot.appendingPathComponent("repository.zip")
        let extractedURL = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try await download(
            Self.githubArchiveURL(coordinate: coordinate, revision: commit.sha),
            to: archiveURL,
            allowedHosts: ["codeload.github.com"],
            maximumBytes: 1 * 1_024 * 1_024 * 1_024,
            accept: "application/zip"
        )
        try SecureArchiveExtractor.extract(
            archiveURL: archiveURL,
            to: extractedURL,
            policy: .github,
            fileManager: fileManager
        )
        let repositoryRoot = try extractedRepositoryRoot(at: extractedURL)
        return try await library.stageFetchedRefresh(
            sourceID: sourceID,
            at: repositoryRoot,
            revisionKind: .gitCommit,
            revision: commit.sha,
            allowLargeImport: allowLargeImport
        )
    }

    private func materializeWebSnapshot(
        html: String,
        requestedURL: URL,
        finalURL: URL,
        at rootURL: URL
    ) async throws -> WebSnapshotManifest {
        let document: Document
        do {
            document = try SwiftSoup.parse(html, finalURL.absoluteString)
        } catch {
            throw AdapterError.unsafeHTML(error.localizedDescription)
        }
        let rawTitle = (try? document.title())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? finalURL.host ?? "网页快照" : rawTitle
        let canonicalHref = try document.select("link[rel~=canonical]")
            .first()?
            .attr("abs:href")
        let canonicalURL = canonicalHref.flatMap(URL.init(string:))
        try document.select("[srcset]").removeAttr("srcset")

        let resourcesURL = rootURL.appendingPathComponent("resources", isDirectory: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        var resourceMap: [String: URL] = [:]
        var totalResourceBytes = 0
        let images = try document.select("img[src]").array()
        for image in images.prefix(64) {
            try Task.checkCancellation()
            let rawSource = try image.attr("src")
            guard !rawSource.lowercased().hasPrefix("data:"),
                  let resourceURL = URL(string: rawSource, relativeTo: finalURL)?.absoluteURL,
                  Self.sameOrigin(resourceURL, finalURL) else {
                if !rawSource.lowercased().hasPrefix("data:") {
                    try image.removeAttr("src")
                }
                continue
            }
            do {
                let payload = try await fetchData(
                    resourceURL,
                    allowedHosts: Set([finalURL.host?.lowercased()].compactMap { $0 }),
                    maximumBytes: 5 * 1_024 * 1_024,
                    accept: "image/*"
                )
                guard payload.response.mimeType?.lowercased().hasPrefix("image/") == true else {
                    try image.removeAttr("src")
                    continue
                }
                totalResourceBytes += payload.data.count
                guard totalResourceBytes <= 50 * 1_024 * 1_024 else {
                    try image.removeAttr("src")
                    continue
                }
                let digest = AdapterUtilities.sha256(payload.data)
                let fileExtension = Self.resourceExtension(
                    url: resourceURL,
                    mediaType: payload.response.mimeType
                )
                let filename = fileExtension.isEmpty ? digest : "\(digest).\(fileExtension)"
                let destination = resourcesURL.appendingPathComponent(filename)
                if !fileManager.fileExists(atPath: destination.path) {
                    try payload.data.write(to: destination, options: .atomic)
                }
                try image.attr("src", "resources/\(filename)")
                resourceMap["resources/\(filename)"] = resourceURL
            } catch {
                if Task.isCancelled { throw CancellationError() }
                try image.removeAttr("src")
            }
        }

        let snapshotHTML = try document.outerHtml()
        try Data(snapshotHTML.utf8).write(
            to: rootURL.appendingPathComponent("index.html"),
            options: .atomic
        )
        let manifest = WebSnapshotManifest(
            schemaVersion: WebSnapshotManifest.schemaVersion,
            requestedURL: requestedURL,
            finalURL: finalURL,
            canonicalURL: canonicalURL.flatMap { candidate in
                Self.sameOrigin(candidate, finalURL) ? candidate : nil
            },
            title: title,
            fetchedAt: .now,
            cachedResources: resourceMap
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: rootURL.appendingPathComponent(WebSnapshotManifest.filename),
            options: .atomic
        )
        return manifest
    }

    private func fetchData(
        _ url: URL,
        allowedHosts: Set<String>,
        maximumBytes: Int64,
        accept: String
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let boundedURL = fileManager.temporaryDirectory.appendingPathComponent(
            "OneReader-Bounded-\(UUID().uuidString.lowercased())"
        )
        defer { try? fileManager.removeItem(at: boundedURL) }
        let response = try await download(
            url,
            to: boundedURL,
            allowedHosts: allowedHosts,
            maximumBytes: maximumBytes,
            accept: accept,
            timeout: 30
        )
        try Task.checkCancellation()
        return (
            try Data(contentsOf: boundedURL, options: [.mappedIfSafe]),
            response
        )
    }

    @discardableResult
    private func download(
        _ url: URL,
        to destination: URL,
        allowedHosts: Set<String>,
        maximumBytes: Int64,
        accept: String,
        timeout: TimeInterval = 120
    ) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("OneReader/0.2", forHTTPHeaderField: "User-Agent")
        let redirectDelegate = OriginBoundRedirectDelegate(
            allowedHosts: allowedHosts,
            maximumBytes: maximumBytes
        )
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(
                for: request,
                delegate: redirectDelegate
            )
        } catch {
            if let actual = redirectDelegate.limitViolation {
                throw RemoteSourceError.payloadTooLarge(
                    limit: maximumBytes,
                    actual: actual
                )
            }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        if let rejectedURL = redirectDelegate.rejectedURL {
            throw RemoteSourceError.redirectRejected(rejectedURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteSourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteSourceError.httpStatus(http.statusCode)
        }
        let actual = Int64(
            (try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        try Self.validateSize(
            response: http,
            actual: actual,
            maximumBytes: maximumBytes
        )
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return http
    }

    private func extractedRepositoryRoot(at extractedURL: URL) throws -> URL {
        let entries = try fileManager.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard entries.count == 1,
              let root = entries.first,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw RemoteSourceError.invalidGitHubArchive
        }
        return root
    }

    static func isGitHubRepositoryURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        guard host == "github.com" || host == "www.github.com" else { return false }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return components.count >= 2
    }

    static func parseGitHubCoordinate(from url: URL) throws -> GitHubRepositoryCoordinate {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw RemoteSourceError.invalidGitHubMetadata
        }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else {
            throw RemoteSourceError.invalidGitHubMetadata
        }
        let repository = parts[1].hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        guard !parts[0].isEmpty, !repository.isEmpty else {
            throw RemoteSourceError.invalidGitHubMetadata
        }
        return GitHubRepositoryCoordinate(owner: parts[0], repository: repository)
    }

    private static func validateWebURL(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" else {
            throw RemoteSourceError.unsupportedScheme(scheme)
        }
        guard url.host?.isEmpty == false else {
            throw RemoteSourceError.invalidResponse
        }
    }

    private static func validateSize(
        response: HTTPURLResponse,
        actual: Int64,
        maximumBytes: Int64
    ) throws {
        let announced = response.expectedContentLength
        if announced > maximumBytes {
            throw RemoteSourceError.payloadTooLarge(limit: maximumBytes, actual: announced)
        }
        if actual > maximumBytes {
            throw RemoteSourceError.payloadTooLarge(limit: maximumBytes, actual: actual)
        }
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func resourceExtension(url: URL, mediaType: String?) -> String {
        if let mediaType,
           let type = UTType(mimeType: mediaType),
           let preferred = type.preferredFilenameExtension {
            return preferred
        }
        let candidate = url.pathExtension.lowercased()
        return candidate.range(of: #"^[a-z0-9]{1,10}$"#, options: .regularExpression) == nil
            ? ""
            : candidate
    }

    private static func remoteFilename(
        response: HTTPURLResponse,
        requestedURL: URL
    ) -> String {
        var candidate = response.suggestedFilename
            ?? requestedURL.lastPathComponent.removingPercentEncoding
            ?? requestedURL.lastPathComponent
        candidate = (candidate as NSString).lastPathComponent
        if candidate.isEmpty || candidate == "/" { candidate = requestedURL.host ?? "remote-source" }
        if (candidate as NSString).pathExtension.isEmpty,
           let mediaType = response.mimeType,
           let fileExtension = UTType(mimeType: mediaType)?.preferredFilenameExtension {
            candidate += ".\(fileExtension)"
        }
        return candidate
    }

    private static func githubAPIURL(_ path: [String]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        components.path = "/" + path.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0
        }.joined(separator: "/")
        return components.url!
    }

    private static func githubArchiveURL(
        coordinate: GitHubRepositoryCoordinate,
        revision: String
    ) -> URL {
        URL(
            string: "https://codeload.github.com/\(coordinate.owner)/\(coordinate.repository)/zip/\(revision)"
        )!
    }

    private static func isFullGitSHA(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil
    }
}

enum RemoteHostValidator {
    static func validate(_ host: String) throws {
        let normalized = host.lowercased()
        guard normalized != "localhost", !normalized.hasSuffix(".localhost") else {
            throw RemoteSourceError.unsafeHost(host)
        }

        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw RemoteSourceError.unsafeHost(host)
        }
        defer { freeaddrinfo(first) }

        var foundAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            defer { cursor = info.ai_next }
            guard let address = info.ai_addr else { continue }
            switch info.ai_family {
            case AF_INET:
                var value = address.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee.sin_addr }
                let bytes = withUnsafeBytes(of: &value) { Array($0.prefix(4)) }
                guard isPublicIPv4(bytes) else {
                    throw RemoteSourceError.unsafeHost(host)
                }
                foundAddress = true
            case AF_INET6:
                var value = address.withMemoryRebound(
                    to: sockaddr_in6.self,
                    capacity: 1
                ) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &value) { Array($0.prefix(16)) }
                guard isPublicIPv6(bytes) else {
                    throw RemoteSourceError.unsafeHost(host)
                }
                foundAddress = true
            default:
                break
            }
        }
        guard foundAddress else {
            throw RemoteSourceError.unsafeHost(host)
        }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        switch first {
        case 0, 10, 127:
            return false
        case 100 where (64...127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16...31).contains(second):
            return false
        case 192 where second == 168
            || (second == 0 && (bytes[2] == 0 || bytes[2] == 2))
            || (second == 88 && bytes[2] == 99):
            return false
        case 198 where second == 18 || second == 19
            || (second == 51 && bytes[2] == 100):
            return false
        case 203 where second == 0 && bytes[2] == 113:
            return false
        case 224...255:
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
        let isNAT64 = bytes[0] == 0x00 && bytes[1] == 0x64
            && bytes[2] == 0xff && bytes[3] == 0x9b
            && (bytes[4..<12].allSatisfy({ $0 == 0 })
                || (bytes[4] == 0 && bytes[5] == 1))
        if isNAT64 { return false }
        let mappedPrefix = bytes.prefix(10).allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff && bytes[11] == 0xff
        if mappedPrefix {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return false }
        return true
    }
}

private struct GitHubSnapshotMetadata: Decodable {
    let name: String
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case name
        case defaultBranch = "default_branch"
    }
}

private struct GitHubSnapshotCommit: Decodable {
    let sha: String
}

final class OriginBoundRedirectDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let allowedHosts: Set<String>
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var storedRejectedURL: URL?
    private var storedLimitViolation: Int64?

    init(allowedHosts: Set<String>, maximumBytes: Int64 = .max) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.maximumBytes = maximumBytes
    }

    var rejectedURL: URL? {
        lock.withLock { storedRejectedURL }
    }

    var limitViolation: Int64? {
        lock.withLock { storedLimitViolation }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            lock.withLock { storedRejectedURL = request.url }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let observed = max(totalBytesWritten, totalBytesExpectedToWrite)
        guard observed > maximumBytes else { return }
        lock.withLock {
            if storedLimitViolation == nil {
                storedLimitViolation = observed
            }
        }
        downloadTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
