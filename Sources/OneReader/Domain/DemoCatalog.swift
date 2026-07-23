import Foundation

enum DemoCatalog {
    static let unresolvedRevision = "unresolved-public-demo"
    static let repositorySourceID = "github:xiaolai/time-as-a-friend"
    static let pdfSourceID = "pdf:xiaolai/time-as-a-friend:third-edition"

    static let repositoryURL = URL(string: "https://github.com/xiaolai/time-as-a-friend")!
    static let pdfURL = URL(
        string: "https://raw.githubusercontent.com/xiaolai/time-as-a-friend/master/pdfs/third-edition.pdf"
    )!

    static let fallbackChapters: [RepositoryChapter] = [
        .init(title: "简介", path: "README.md", order: 0),
        .init(title: "历次出版前言", path: "Preface.md", order: 1),
        .init(title: "序", path: "Forword.md", order: 2),
        .init(title: "第0章 困境", path: "Chapter0.md", order: 3),
        .init(title: "第1章 醒悟", path: "Chapter1.md", order: 4),
        .init(title: "第2章 现实", path: "Chapter2.md", order: 5),
        .init(title: "第3章 管理", path: "Chapter3.md", order: 6),
        .init(title: "第4章 学习", path: "Chapter4.md", order: 7),
        .init(title: "第5章 思考", path: "Chapter5.md", order: 8),
        .init(title: "第6章 交流", path: "Chapter6.md", order: 9),
        .init(title: "第7章 应用", path: "Chapter7.md", order: 10)
    ]

    // Public third-edition page starts. These are alignment hints for the demo,
    // not semantic claims. Imported PDFs use their own outline/page mapping.
    static let pdfPageHints: [String: Int] = [
        "README.md": 4,
        "Preface.md": 7,
        "Forword.md": 10,
        "Chapter0.md": 12,
        "Chapter1.md": 21,
        "Chapter2.md": 34,
        "Chapter3.md": 55,
        "Chapter4.md": 113,
        "Chapter5.md": 142,
        "Chapter6.md": 192,
        "Chapter7.md": 225
    ]

    static var unresolvedRepositorySource: ReadingSource {
        ReadingSource(
            id: repositorySourceID,
            title: "把时间当作朋友 · Repo",
            kind: .githubRepository,
            origin: repositoryURL,
            revision: nil,
            capabilities: [.list, .read, .search, .resolve],
            availability: .resolving,
            detail: "正在解析公开仓库"
        )
    }

    static var unresolvedRepositorySnapshot: SourceSnapshot {
        SourceSnapshot(
            sourceID: repositorySourceID,
            revision: unresolvedRevision,
            observedAt: .now,
            origin: repositoryURL
        )
    }

    static var unresolvedPDFSource: ReadingSource {
        ReadingSource(
            id: pdfSourceID,
            title: "把时间当作朋友 · 第三版 PDF",
            kind: .pdf,
            origin: pdfURL,
            revision: nil,
            capabilities: [.list, .read, .render, .search, .resolve],
            availability: .resolving,
            detail: "按需载入 306 页"
        )
    }

    static var unresolvedPDFSnapshot: SourceSnapshot {
        SourceSnapshot(
            sourceID: pdfSourceID,
            revision: unresolvedRevision,
            observedAt: .now,
            origin: pdfURL
        )
    }
}

