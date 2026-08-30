import Foundation
import XCTest
@testable import OneReader

final class ReadingGraphTests: XCTestCase {
    private let mapper = DeterministicSemanticMapper()
    private let planner = ReadingPlanner()
    private let sourceID = "github:fixture/reader"
    private let repositoryURL = URL(string: "https://github.com/fixture/reader")!
    private let chapters = [
        RepositoryChapter(title: "Introduction", path: "README.md", order: 0),
        RepositoryChapter(title: "Concepts", path: "Chapter3.md", order: 1),
        RepositoryChapter(title: "Practice", path: "Appendix.md", order: 2),
    ]

    func testEveryMappedUnitRetainsRevisionBoundEvidence() {
        let snapshot = SourceSnapshot(
            sourceID: sourceID,
            revision: "abc123",
            observedAt: Date(timeIntervalSince1970: 1),
            origin: repositoryURL
        )

        let graph = mapper.mapRepositoryBook(
            title: "Test Book",
            repositorySnapshot: snapshot,
            chapters: chapters,
            pdfSnapshot: nil,
            pdfPageHints: [:]
        )

        XCTAssertFalse(graph.units.isEmpty)
        XCTAssertTrue(graph.units.allSatisfy { !$0.fragments.isEmpty })
        XCTAssertTrue(
            graph.units
                .flatMap(\.fragments)
                .allSatisfy { $0.locator.snapshotID == snapshot.id }
        )
    }

    func testGraphVersionChangesWhenSnapshotChanges() {
        let first = graph(revision: "first")
        let second = graph(revision: "second")

        XCTAssertNotEqual(first.version, second.version)
        XCTAssertEqual(first.units.map(\.id), second.units.map(\.id))
    }

    func testPlansProjectSameGraphDifferently() {
        let graph = graph(revision: "abc123")
        let progress = ReadingProgress.empty

        let systematic = planner.makePlan(
            graph: graph,
            goal: .systematic,
            progress: progress
        )
        let quick = planner.makePlan(
            graph: graph,
            goal: .quickOverview,
            progress: progress
        )

        XCTAssertEqual(systematic.orderedUnits.first?.unitID, quick.orderedUnits.first?.unitID)
        XCTAssertNotEqual(
            systematic.orderedUnits.map(\.unitID),
            quick.orderedUnits.map(\.unitID)
        )
        XCTAssertEqual(
            Set(systematic.orderedUnits.map(\.unitID)),
            Set(quick.orderedUnits.map(\.unitID))
        )
    }

    func testReviewPlanMovesCompletedUnitsAfterIncompleteUnits() {
        let graph = graph(revision: "abc123")
        let firstID = graph.units[0].id
        var progress = ReadingProgress.empty
        progress.units[firstID] = UnitProgress(
            unitID: firstID,
            state: .completed,
            fraction: 1,
            updatedAt: .now
        )

        let review = planner.makePlan(
            graph: graph,
            goal: .review,
            progress: progress
        )

        XCTAssertNotEqual(review.orderedUnits.first?.unitID, firstID)
        XCTAssertEqual(review.orderedUnits.last?.unitID, firstID)
    }

    private func graph(revision: String) -> ReadingGraph {
        mapper.mapRepositoryBook(
            title: "Test Book",
            repositorySnapshot: SourceSnapshot(
                sourceID: sourceID,
                revision: revision,
                observedAt: Date(timeIntervalSince1970: 1),
                origin: repositoryURL
            ),
            chapters: chapters,
            pdfSnapshot: nil,
            pdfPageHints: [:]
        )
    }
}
