import CryptoKit
import Foundation
import PDFKit

enum PDFBookSourceError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "PDF 下载返回了无法识别的响应。"
        case let .httpStatus(status):
            "PDF 下载失败（HTTP \(status)）。"
        case .invalidDocument:
            "PDFKit 无法打开这个文件。"
        }
    }
}

struct PDFInspection: Sendable {
    let source: ReadingSource
    let snapshot: SourceSnapshot
    let sections: [PDFSection]
    let pageCount: Int
}

enum PDFBookSource {
    static func loadRemoteData(
        from url: URL,
        session: URLSession = .shared
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("OneReader/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PDFBookSourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PDFBookSourceError.httpStatus(http.statusCode)
        }
        return data
    }

    @MainActor
    static func inspect(
        data: Data,
        title: String,
        sourceID: String,
        origin: URL?
    ) throws -> (PDFDocument, PDFInspection) {
        guard let document = PDFDocument(data: data) else {
            throw PDFBookSourceError.invalidDocument
        }
        let revision = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let source = ReadingSource(
            id: sourceID,
            title: title,
            kind: .pdf,
            origin: origin,
            revision: revision,
            capabilities: [.list, .read, .render, .search, .resolve],
            availability: .ready,
            detail: "\(document.pageCount) 页 · \(revision.prefix(7))"
        )
        let snapshot = SourceSnapshot(
            sourceID: sourceID,
            revision: revision,
            observedAt: .now,
            origin: origin
        )
        let sections = outlineSections(in: document)
        return (
            document,
            PDFInspection(
                source: source,
                snapshot: snapshot,
                sections: sections,
                pageCount: document.pageCount
            )
        )
    }

    @MainActor
    private static func outlineSections(in document: PDFDocument) -> [PDFSection] {
        var discovered: [(String, Int)] = []
        if let root = document.outlineRoot {
            collectOutlineChildren(root, document: document, depth: 0, into: &discovered)
        }

        let unique = discovered.reduce(into: [(String, Int)]()) { result, candidate in
            guard !result.contains(where: { $0.1 == candidate.1 }) else { return }
            result.append(candidate)
        }
        if !unique.isEmpty {
            return unique
                .sorted { left, right in
                    if left.1 == right.1 { return left.0 < right.0 }
                    return left.1 < right.1
                }
                .enumerated()
                .map { index, item in
                    PDFSection(
                        id: "outline:\(item.1):\(index)",
                        title: item.0,
                        pageIndex: item.1,
                        order: index
                    )
                }
        }

        let groupSize = document.pageCount > 120 ? 20 : 12
        return stride(from: 0, to: max(document.pageCount, 1), by: groupSize)
            .enumerated()
            .map { index, pageIndex in
                let lastPage = min(pageIndex + groupSize, document.pageCount)
                return PDFSection(
                    id: "pages:\(pageIndex)",
                    title: "第 \(pageIndex + 1)–\(lastPage) 页",
                    pageIndex: pageIndex,
                    order: index
                )
            }
    }

    @MainActor
    private static func collectOutlineChildren(
        _ outline: PDFOutline,
        document: PDFDocument,
        depth: Int,
        into result: inout [(String, Int)]
    ) {
        guard depth <= 1 else { return }
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if
                let page = child.destination?.page,
                let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty
            {
                let pageIndex = document.index(for: page)
                if pageIndex >= 0 {
                    result.append((label, pageIndex))
                }
            }
            collectOutlineChildren(
                child,
                document: document,
                depth: depth + 1,
                into: &result
            )
        }
    }
}

