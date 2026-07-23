import CryptoKit
import Foundation

protocol SemanticMapping: Sendable {
    func mapRepositoryBook(
        title: String,
        repositorySnapshot: SourceSnapshot,
        chapters: [RepositoryChapter],
        pdfSnapshot: SourceSnapshot?,
        pdfPageHints: [String: Int]
    ) -> ReadingGraph

    func mapPDF(
        title: String,
        snapshot: SourceSnapshot,
        sections: [PDFSection]
    ) -> ReadingGraph
}

struct DeterministicSemanticMapper: SemanticMapping {
    static let mapperID = "onereader.deterministic-structure"
    static let mapperVersion = "1"

    func mapRepositoryBook(
        title: String,
        repositorySnapshot: SourceSnapshot,
        chapters: [RepositoryChapter],
        pdfSnapshot: SourceSnapshot?,
        pdfPageHints: [String: Int]
    ) -> ReadingGraph {
        let graphSeed = [
            repositorySnapshot.id,
            pdfSnapshot?.id ?? "no-pdf",
            chapters.map(\.path).joined(separator: "|"),
            Self.mapperVersion
        ].joined(separator: "::")
        let graphVersion = Self.stableDigest(graphSeed)

        let units = chapters.enumerated().map { index, chapter in
            let unitID = "repo:\(repositorySnapshot.sourceID):\(chapter.path)"
            var fragments = [
                SourceFragment(
                    id: "\(unitID):repository",
                    sourceID: repositorySnapshot.sourceID,
                    locator: Locator(
                        sourceID: repositorySnapshot.sourceID,
                        sourceRevision: repositorySnapshot.revision,
                        native: .repository(path: chapter.path, startLine: nil, endLine: nil),
                        textAnchor: TextAnchor(prefix: nil, exact: chapter.title, suffix: nil),
                        fingerprint: nil
                    ),
                    role: .primary,
                    label: chapter.path
                )
            ]

            if let pdfSnapshot, let pageIndex = pdfPageHints[chapter.path] {
                fragments.append(
                    SourceFragment(
                        id: "\(unitID):pdf",
                        sourceID: pdfSnapshot.sourceID,
                        locator: Locator(
                            sourceID: pdfSnapshot.sourceID,
                            sourceRevision: pdfSnapshot.revision,
                            native: .pdf(pageIndex: pageIndex),
                            textAnchor: TextAnchor(prefix: nil, exact: chapter.title, suffix: nil),
                            fingerprint: nil
                        ),
                        role: .reference,
                        label: "第三版 PDF · 第 \(pageIndex + 1) 页"
                    )
                )
            }

            var relations: [UnitRelation] = []
            if index > 0 {
                let previous = chapters[index - 1]
                relations.append(
                    UnitRelation(
                        targetUnitID: "repo:\(repositorySnapshot.sourceID):\(previous.path)",
                        type: .prerequisite,
                        weight: 0.72,
                        confidence: 0.94,
                        isHardConstraint: false
                    )
                )
            }
            if index + 1 < chapters.count {
                let next = chapters[index + 1]
                relations.append(
                    UnitRelation(
                        targetUnitID: "repo:\(repositorySnapshot.sourceID):\(next.path)",
                        type: .follows,
                        weight: 0.86,
                        confidence: 0.98,
                        isHardConstraint: false
                    )
                )
            }

            return ReadingUnit(
                id: unitID,
                title: chapter.title,
                summary: Self.summary(for: chapter),
                fragments: fragments,
                relations: relations,
                estimatedMinutes: Self.estimatedMinutes(for: chapter),
                importance: Self.importance(for: chapter),
                confidence: 0.96,
                sourceOrder: chapter.order,
                preferredPresentation: fragments.count > 1 ? .comparison : .repository
            )
        }

        return ReadingGraph(
            id: "graph:\(repositorySnapshot.sourceID)",
            version: graphVersion,
            title: title,
            sourceSnapshots: [repositorySnapshot] + [pdfSnapshot].compactMap { $0 },
            units: units,
            mapperID: Self.mapperID,
            mapperVersion: Self.mapperVersion,
            generatedAt: .now
        )
    }

    func mapPDF(
        title: String,
        snapshot: SourceSnapshot,
        sections: [PDFSection]
    ) -> ReadingGraph {
        let graphVersion = Self.stableDigest(
            ([snapshot.id] + sections.map { "\($0.title):\($0.pageIndex)" })
                .joined(separator: "::")
        )

        let units = sections.enumerated().map { index, section in
            let unitID = "pdf:\(snapshot.sourceID):\(section.pageIndex)"
            var relations: [UnitRelation] = []
            if index > 0 {
                relations.append(
                    UnitRelation(
                        targetUnitID: "pdf:\(snapshot.sourceID):\(sections[index - 1].pageIndex)",
                        type: .prerequisite,
                        weight: 0.7,
                        confidence: 0.9,
                        isHardConstraint: false
                    )
                )
            }
            return ReadingUnit(
                id: unitID,
                title: section.title,
                summary: "从原生 PDF 第 \(section.pageIndex + 1) 页开始阅读。",
                fragments: [
                    SourceFragment(
                        id: "\(unitID):primary",
                        sourceID: snapshot.sourceID,
                        locator: Locator(
                            sourceID: snapshot.sourceID,
                            sourceRevision: snapshot.revision,
                            native: .pdf(pageIndex: section.pageIndex),
                            textAnchor: TextAnchor(prefix: nil, exact: section.title, suffix: nil),
                            fingerprint: nil
                        ),
                        role: .primary,
                        label: "第 \(section.pageIndex + 1) 页"
                    )
                ],
                relations: relations,
                estimatedMinutes: 12,
                importance: index == 0 ? 1 : 0.72,
                confidence: 0.9,
                sourceOrder: section.order,
                preferredPresentation: .pdf
            )
        }

        return ReadingGraph(
            id: "graph:\(snapshot.sourceID)",
            version: graphVersion,
            title: title,
            sourceSnapshots: [snapshot],
            units: units,
            mapperID: Self.mapperID,
            mapperVersion: Self.mapperVersion,
            generatedAt: .now
        )
    }

    static func stableDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func summary(for chapter: RepositoryChapter) -> String {
        switch chapter.path {
        case "README.md": "先理解这本书的定位、阅读方式与整体目录。"
        case "Preface.md": "沿版本演进理解作者为什么反复修订这套认知框架。"
        case "Forword.md": "从序言建立作者、读者与问题之间的关系。"
        case "Chapter0.md": "识别时间、困境与个人选择之间最初的矛盾。"
        case "Chapter1.md": "从自我觉察开始，建立可持续改变的起点。"
        case "Chapter2.md": "接受现实约束，为后续管理与积累建立地基。"
        case "Chapter3.md": "把抽象目标落到任务、时间与执行系统。"
        case "Chapter4.md": "理解学习如何通过长期积累产生复利。"
        case "Chapter5.md": "检查思考方法、证据与判断之间的关系。"
        case "Chapter6.md": "理解有效交流的前提、成本与边界。"
        case "Chapter7.md": "把前面的认知原则投射到长期行动。"
        default: "沿原始材料结构阅读，并随时回到对应证据。"
        }
    }

    private static func importance(for chapter: RepositoryChapter) -> Double {
        switch chapter.path {
        case "README.md": 1
        case "Chapter1.md", "Chapter2.md", "Chapter3.md", "Chapter4.md": 0.95
        case "Chapter5.md", "Chapter6.md", "Chapter7.md": 0.9
        case "Chapter0.md": 0.82
        default: 0.62
        }
    }

    private static func estimatedMinutes(for chapter: RepositoryChapter) -> Int {
        switch chapter.path {
        case "Chapter3.md", "Chapter5.md", "Chapter7.md": 36
        case "Chapter2.md", "Chapter4.md", "Chapter6.md": 28
        case "Chapter0.md", "Chapter1.md": 20
        default: 10
        }
    }
}

