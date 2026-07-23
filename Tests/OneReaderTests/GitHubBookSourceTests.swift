import Foundation
import XCTest
@testable import OneReader

final class GitHubBookSourceTests: XCTestCase {
    func testParsesRepositoryCoordinate() throws {
        let coordinate = try GitHubBookSource.parseCoordinate(
            from: URL(string: "https://github.com/xiaolai/time-as-a-friend/tree/master")!
        )

        XCTAssertEqual(coordinate.owner, "xiaolai")
        XCTAssertEqual(coordinate.repository, "time-as-a-friend")
    }

    func testRejectsUnsupportedHost() {
        XCTAssertThrowsError(
            try GitHubBookSource.parseCoordinate(
                from: URL(string: "https://example.com/xiaolai/time-as-a-friend")!
            )
        ) { error in
            XCTAssertEqual(error as? GitHubBookSourceError, .unsupportedHost)
        }
    }

    func testParsesChineseTableOfContents() {
        let markdown = """
        # 一本书

        ## 目录

        * [简介](README.md)
        * [第0章 困境](Chapter0.md)
        * [第1章 醒悟](chapters/Chapter1.md#section)

        ## 其他

        * [外部链接](https://example.com)
        """

        let chapters = GitHubReadmeTOCParser().parse(markdown)

        XCTAssertEqual(
            chapters,
            [
                RepositoryChapter(title: "简介", path: "README.md", order: 0),
                RepositoryChapter(title: "第0章 困境", path: "Chapter0.md", order: 1),
                RepositoryChapter(title: "第1章 醒悟", path: "chapters/Chapter1.md", order: 2)
            ]
        )
    }
}

