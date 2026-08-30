import CryptoKit
import Foundation

enum GitHubBookSourceError: LocalizedError, Equatable {
    case invalidRepositoryURL
    case unsupportedHost
    case invalidResponse
    case httpStatus(Int)
    case missingReadme
    case emptyBook

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL:
            "请输入形如 https://github.com/owner/repository 的地址。"
        case .unsupportedHost:
            "第一版只支持公开 GitHub 仓库。"
        case .invalidResponse:
            "GitHub 返回了无法识别的响应。"
        case let .httpStatus(status):
            "GitHub 请求失败（HTTP \(status)）。"
        case .missingReadme:
            "仓库中没有可读取的 README.md。"
        case .emptyBook:
            "没有在目录或仓库树中找到 Markdown 阅读单元。"
        }
    }
}

struct GitHubReadmeTOCParser: Sendable {
    func parse(_ markdown: String) -> [RepositoryChapter] {
        let lines = markdown.components(separatedBy: .newlines)
        var insideTableOfContents = false
        var entries: [RepositoryChapter] = []
        let pattern = #"^\s*[-*+]\s+\[([^\]]+)\]\(([^)]+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(
                of: #"^#{1,6}\s*(目录|Table\s+of\s+Contents)\s*$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                insideTableOfContents = true
                continue
            }

            if insideTableOfContents, trimmed.hasPrefix("#") {
                break
            }
            guard insideTableOfContents else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard
                let match = regex.firstMatch(in: line, range: range),
                let titleRange = Range(match.range(at: 1), in: line),
                let targetRange = Range(match.range(at: 2), in: line)
            else {
                continue
            }

            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTarget = String(line[targetRange])
            let path = rawTarget
                .split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .removingPercentEncoding ?? rawTarget

            guard
                !path.contains("://"),
                path.lowercased().hasSuffix(".md")
            else {
                continue
            }
            entries.append(
                RepositoryChapter(title: title, path: path, order: entries.count)
            )
        }
        return entries
    }
}

actor GitHubBookSource {
    private let session: URLSession
    private let parser = GitHubReadmeTOCParser()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func loadBook(from repositoryURL: URL) async throws -> RepositoryBook {
        let coordinate = try Self.parseCoordinate(from: repositoryURL)
        let metadata: RepositoryMetadata = try await requestJSON(
            apiURL(["repos", coordinate.owner, coordinate.repository])
        )
        let branch: BranchResponse = try await requestJSON(
            apiURL([
                "repos",
                coordinate.owner,
                coordinate.repository,
                "branches",
                metadata.defaultBranch
            ])
        )

        async let readme = requestText(
            rawURL(
                coordinate: coordinate,
                revision: branch.commit.sha,
                path: "README.md"
            )
        )
        async let tree: TreeResponse = requestJSON(
            apiURL([
                "repos",
                coordinate.owner,
                coordinate.repository,
                "git",
                "trees",
                branch.commit.sha
            ], query: [URLQueryItem(name: "recursive", value: "1")])
        )

        let (readmeText, repositoryTree) = try await (readme, tree)
        var chapters = parser.parse(readmeText)
        if chapters.isEmpty {
            let paths = repositoryTree.tree
                .filter { $0.type == "blob" && $0.path.lowercased().hasSuffix(".md") }
                .map(\.path)
                .sorted(by: Self.naturalPathOrder)
            chapters = paths.enumerated().map { index, path in
                RepositoryChapter(
                    title: Self.displayTitle(for: path),
                    path: path,
                    order: index
                )
            }
        }
        guard !chapters.isEmpty else {
            throw GitHubBookSourceError.emptyBook
        }

        let sourceID = "github:\(coordinate.slug)"
        let source = ReadingSource(
            id: sourceID,
            title: metadata.name,
            kind: .githubRepository,
            origin: repositoryURL,
            revision: branch.commit.sha,
            capabilities: [.list, .read, .search, .resolve],
            availability: .ready,
            detail: "\(chapters.count) 个阅读单元 · \(branch.commit.sha.prefix(7))"
        )
        let snapshot = SourceSnapshot(
            sourceID: sourceID,
            revision: branch.commit.sha,
            observedAt: .now,
            origin: repositoryURL
        )
        return RepositoryBook(
            coordinate: coordinate,
            defaultBranch: metadata.defaultBranch,
            source: source,
            snapshot: snapshot,
            chapters: chapters
        )
    }

    func readMarkdown(
        coordinate: RepositoryCoordinate,
        revision: String,
        path: String
    ) async throws -> Observation {
        let sourceID = "github:\(coordinate.slug)"
        let url = rawURL(coordinate: coordinate, revision: revision, path: path)
        let markdown = try await requestText(url)
        let digest = SHA256.hash(data: Data(markdown.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let locator = Locator(
            sourceID: sourceID,
            snapshotID: "\(sourceID)@\(revision)",
            adapterID: "onereader.github-markdown",
            payload: ["path": path],
            structuralPath: path,
            textQuote: nil,
            fingerprint: digest
        )
        return Observation(
            id: "\(locator.stableID):\(digest.prefix(12))",
            sourceID: sourceID,
            snapshotID: locator.snapshotID,
            adapterID: locator.adapterID,
            locator: locator,
            mediaType: "text/markdown",
            content: markdown,
            contentReference: nil,
            contentDigest: digest,
            truncated: false,
            observedAt: .now
        )
    }

    static func parseCoordinate(from url: URL) throws -> RepositoryCoordinate {
        guard let host = url.host?.lowercased() else {
            throw GitHubBookSourceError.invalidRepositoryURL
        }
        guard host == "github.com" || host == "www.github.com" else {
            throw GitHubBookSourceError.unsupportedHost
        }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2 else {
            throw GitHubBookSourceError.invalidRepositoryURL
        }
        let repository = parts[1].hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        guard !parts[0].isEmpty, !repository.isEmpty else {
            throw GitHubBookSourceError.invalidRepositoryURL
        }
        return RepositoryCoordinate(owner: parts[0], repository: repository)
    }

    private func requestText(_ url: URL) async throws -> String {
        let (data, response) = try await request(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubBookSourceError.invalidResponse
        }
        _ = response
        return text
    }

    private func requestJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await request(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubBookSourceError.invalidResponse
        }
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OneReader/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubBookSourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404, url.lastPathComponent.lowercased() == "readme.md" {
                throw GitHubBookSourceError.missingReadme
            }
            throw GitHubBookSourceError.httpStatus(http.statusCode)
        }
        return (data, http)
    }

    private func apiURL(
        _ pathComponents: [String],
        query: [URLQueryItem] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/" + pathComponents
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? component
            }
            .joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func rawURL(
        coordinate: RepositoryCoordinate,
        revision: String,
        path: String
    ) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return URL(
            string: "https://raw.githubusercontent.com/\(coordinate.owner)/\(coordinate.repository)/\(revision)/\(encodedPath)"
        )!
    }

    private static func naturalPathOrder(_ left: String, _ right: String) -> Bool {
        left.localizedStandardCompare(right) == .orderedAscending
    }

    private static func displayTitle(for path: String) -> String {
        let name = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        return name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

private struct RepositoryMetadata: Decodable, Sendable {
    let name: String
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case name
        case defaultBranch = "default_branch"
    }
}

private struct BranchResponse: Decodable, Sendable {
    let commit: Commit

    struct Commit: Decodable, Sendable {
        let sha: String
    }
}

private struct TreeResponse: Decodable, Sendable {
    let tree: [TreeItem]

    struct TreeItem: Decodable, Sendable {
        let path: String
        let type: String
    }
}
