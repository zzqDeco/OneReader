import Foundation
import XCTest
@testable import OneReader

@MainActor
final class DeskLifecycleAndNotesTests: XCTestCase {
    func testRenameSpaceAndSourcePersistsAndUpdatesAppModel() async throws {
        let root = makeTemporaryRoot("RenameSpaceAndSource")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("article.md")
        try Data("# Original Title\n\nEvidence body.\n".utf8).write(to: sourceURL)

        let model = try await makeBootstrappedModel(root: root)
        model.importLocalURLs([sourceURL])
        try await waitUntil {
            model.spaces.count == 1 && model.sources.count == 1 && model.activePendingImportCount == 0
        }

        let space = try XCTUnwrap(model.spaces.first)
        let source = try XCTUnwrap(model.sources.first)
        let database = try XCTUnwrap(model.database)

        model.requestSpaceRename(space)
        XCTAssertEqual(model.spacePendingRename?.id, space.id)
        model.renameSpace(space.id, title: "  专题研读桌  ")
        XCTAssertNil(model.spacePendingRename)
        XCTAssertEqual(model.spaces.first?.title, "专题研读桌")
        XCTAssertEqual(try database.fetchSpaces().first?.title, "专题研读桌")

        model.requestSourceRename(source)
        XCTAssertEqual(model.sourcePendingRename?.id, source.id)
        model.renameSource(source.id, displayName: "  核心论文.md  ")
        XCTAssertNil(model.sourcePendingRename)
        XCTAssertEqual(model.sources.first?.displayName, "核心论文.md")
        XCTAssertEqual(try database.fetchSources().first?.displayName, "核心论文.md")

        model.renameSpace(space.id, title: "   ")
        XCTAssertEqual(model.notice?.title, "无法重命名空间")
        XCTAssertEqual(model.spaces.first?.title, "专题研读桌")
    }

    func testCrossSpaceAnnotationsCarryOverFromInboxToTargetSpaceWithoutDuplication() async throws {
        let root = makeTemporaryRoot("CrossSpaceAnnotations")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("inbox-note.md")
        let targetSeedURL = root.appendingPathComponent("target-seed.md")
        try Data("# Inbox Capture\n\nImportant paragraph with evidence.\n".utf8).write(to: sourceURL)
        try Data("# Target Seed\n\nTarget space content.\n".utf8).write(to: targetSeedURL)

        let model = try await makeBootstrappedModel(root: root)
        let database = try XCTUnwrap(model.database)
        let library = try XCTUnwrap(model.managedLibrary)

        let inboxResult = try await library.importLocalSource(at: sourceURL)
        try database.setSpaceOrganization(.inbox, spaceIDs: [inboxResult.space.id])

        let locator = Locator(
            sourceID: inboxResult.source.id,
            snapshotID: inboxResult.snapshot.id,
            adapterID: "markdown-text",
            payload: ["relativePath": "inbox-note.md"],
            structuralPath: "Inbox Capture",
            textQuote: TextQuote(prefix: nil, exact: "Important paragraph", suffix: nil),
            fingerprint: inboxResult.snapshot.digest
        )
        let annotation = Annotation(
            id: "inbox-annotation-1",
            spaceID: inboxResult.space.id,
            sourceID: inboxResult.source.id,
            snapshotID: inboxResult.snapshot.id,
            kind: .note,
            locator: locator,
            anchorState: .current,
            selectedText: "Important paragraph",
            note: "收集箱里的初始批注",
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        try database.saveAnnotation(annotation)

        let targetImport = try await library.importLocalSource(at: targetSeedURL)
        let targetSpace = targetImport.space
        try database.attachSourceToSpace(
            sourceID: inboxResult.source.id,
            spaceID: targetSpace.id
        )

        let targetAnnotations = try database.fetchAnnotations(spaceID: targetSpace.id)
        XCTAssertEqual(targetAnnotations.map(\.id), [annotation.id])

        let sourceFilteredAnnotations = try database.fetchAnnotations(
            spaceID: targetSpace.id,
            sourceID: inboxResult.source.id
        )
        XCTAssertEqual(sourceFilteredAnnotations.map(\.id), [annotation.id])

        try model.reloadLibraryState()
        model.openSpace(targetSpace.id)
        try await waitUntil {
            model.selectedSpaceID == targetSpace.id && model.annotations.map(\.id) == [annotation.id]
        }
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations.first?.note, "收集箱里的初始批注")

        try database.deleteAnnotation(id: annotation.id, spaceID: targetSpace.id)
        XCTAssertTrue(try database.fetchAnnotations(spaceID: targetSpace.id).isEmpty)
    }

    func testDetachSharedSourcePreservesSourceAndAnnotationsInOtherSpace() async throws {
        let root = makeTemporaryRoot("DetachSharedSource")
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = root.appendingPathComponent("shared.md")
        let url2 = root.appendingPathComponent("second.md")
        let url3 = root.appendingPathComponent("other-space.md")
        try Data("# Shared\n\nShared content.\n".utf8).write(to: url1)
        try Data("# Second\n\nSecond content.\n".utf8).write(to: url2)
        try Data("# Other\n\nOther space content.\n".utf8).write(to: url3)

        let model = try await makeBootstrappedModel(root: root)
        let database = try XCTUnwrap(model.database)
        let library = try XCTUnwrap(model.managedLibrary)

        let imported1 = try await library.importLocalSource(at: url1)
        let imported2 = try await library.importLocalSource(
            at: url2,
            intoSpaceID: imported1.space.id
        )

        let secondSpaceImport = try await library.importLocalSource(at: url3)
        let secondSpace = secondSpaceImport.space
        try database.attachSourceToSpace(
            sourceID: imported1.source.id,
            spaceID: secondSpace.id
        )

        let annotation = Annotation(
            id: "shared-annotation-1",
            spaceID: imported1.space.id,
            sourceID: imported1.source.id,
            snapshotID: imported1.snapshot.id,
            kind: .bookmark,
            locator: Locator(
                sourceID: imported1.source.id,
                snapshotID: imported1.snapshot.id,
                adapterID: "markdown-text",
                payload: ["relativePath": "shared.md"],
                structuralPath: nil,
                textQuote: nil,
                fingerprint: imported1.snapshot.digest
            ),
            anchorState: .current,
            selectedText: nil,
            note: "跨空间保留书签",
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        try database.saveAnnotation(annotation)

        try model.reloadLibraryState()
        model.openSpace(imported1.space.id, preferredSourceID: imported1.source.id)

        XCTAssertTrue(model.canDetachSource(imported1.source.id, fromSpaceID: imported1.space.id))
        XCTAssertTrue(model.canDetachSource(imported1.source.id, fromSpaceID: secondSpace.id))

        model.detachSourceFromSpace(sourceID: imported1.source.id, spaceID: imported1.space.id)

        XCTAssertEqual(model.sourceIDs(in: imported1.space.id), [imported2.source.id])
        XCTAssertEqual(
            model.sourceIDs(in: secondSpace.id),
            [secondSpaceImport.source.id, imported1.source.id]
        )
        XCTAssertNotNil(model.source(id: imported1.source.id))

        let remainingInFirstSpace = try database.fetchAnnotations(spaceID: imported1.space.id)
        XCTAssertTrue(remainingInFirstSpace.isEmpty)

        let preservedInSecondSpace = try database.fetchAnnotations(spaceID: secondSpace.id)
        XCTAssertEqual(preservedInSecondSpace.map(\.id), [annotation.id])
    }

    func testDeleteSpaceRemovesExclusiveSourcesAndPreservesSharedSources() async throws {
        let root = makeTemporaryRoot("DeleteSpaceExclusiveVsShared")
        defer { try? FileManager.default.removeItem(at: root) }

        let exclusiveURL = root.appendingPathComponent("exclusive.md")
        let sharedURL = root.appendingPathComponent("shared.md")
        let spaceBSeedURL = root.appendingPathComponent("space-b-seed.md")
        try Data("# Exclusive\n\nOnly in space A.\n".utf8).write(to: exclusiveURL)
        try Data("# Shared\n\nIn space A and B.\n".utf8).write(to: sharedURL)
        try Data("# Space B\n\nSpace B seed.\n".utf8).write(to: spaceBSeedURL)

        let model = try await makeBootstrappedModel(root: root)
        let database = try XCTUnwrap(model.database)
        let library = try XCTUnwrap(model.managedLibrary)

        let exclusiveImport = try await library.importLocalSource(at: exclusiveURL)
        let spaceAID = exclusiveImport.space.id
        let sharedImport = try await library.importLocalSource(at: sharedURL, intoSpaceID: spaceAID)

        let spaceBImport = try await library.importLocalSource(at: spaceBSeedURL)
        let spaceB = spaceBImport.space
        try database.attachSourceToSpace(
            sourceID: sharedImport.source.id,
            spaceID: spaceB.id
        )

        let sharedAnnotation = Annotation(
            id: "shared-annot-keep",
            spaceID: spaceAID,
            sourceID: sharedImport.source.id,
            snapshotID: sharedImport.snapshot.id,
            kind: .note,
            locator: Locator(
                sourceID: sharedImport.source.id,
                snapshotID: sharedImport.snapshot.id,
                adapterID: "markdown-text",
                payload: ["relativePath": "shared.md"],
                structuralPath: nil,
                textQuote: nil,
                fingerprint: sharedImport.snapshot.digest
            ),
            anchorState: .current,
            selectedText: "In space A and B.",
            note: "删除空间 A 后仍应保留",
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        try database.saveAnnotation(sharedAnnotation)

        let exclusiveIDs = try database.exclusivelyOwnedSourceIDs(inSpaceID: spaceAID)
        XCTAssertEqual(exclusiveIDs, [exclusiveImport.source.id])

        try model.reloadLibraryState()
        model.openSpace(spaceAID)

        let spaceA = try XCTUnwrap(model.spaces.first(where: { $0.id == spaceAID }))
        model.requestSpaceDeletion(spaceA)
        XCTAssertEqual(model.spacePendingDeletion?.id, spaceAID)
        model.confirmSpaceDeletion()

        try await waitUntil {
            !model.spaces.contains(where: { $0.id == spaceAID })
        }

        XCTAssertNil(model.spacePendingDeletion)
        XCTAssertFalse(model.isReadingWorkspaceOpen)
        XCTAssertNil(model.selectedSpaceID)
        XCTAssertNil(model.source(id: exclusiveImport.source.id))
        XCTAssertNotNil(model.source(id: sharedImport.source.id))
        XCTAssertEqual(
            model.sourceIDs(in: spaceB.id),
            [spaceBImport.source.id, sharedImport.source.id]
        )

        let spaceBAnnotations = try database.fetchAnnotations(spaceID: spaceB.id)
        XCTAssertEqual(spaceBAnnotations.map(\.id), [sharedAnnotation.id])
    }

    func testReferenceSourceRoleDoesNotDilutePrimaryReadingProgress() async throws {
        let root = makeTemporaryRoot("ReferenceSourceRoleProgress")
        defer { try? FileManager.default.removeItem(at: root) }

        let primaryURL = root.appendingPathComponent("primary.md")
        let referenceURL = root.appendingPathComponent("dictionary.md")
        try Data("# Primary\n\nMain reading text.\n".utf8).write(to: primaryURL)
        try Data("# Reference\n\nGlossary reference.\n".utf8).write(to: referenceURL)

        let model = try await makeBootstrappedModel(root: root)
        let database = try XCTUnwrap(model.database)
        let library = try XCTUnwrap(model.managedLibrary)

        let primaryImport = try await library.importLocalSource(at: primaryURL)
        let spaceID = primaryImport.space.id
        let referenceImport = try await library.importLocalSource(at: referenceURL, intoSpaceID: spaceID)

        var progress = ReadingProgress.empty
        progress.sourcePositions[primaryImport.source.id] = SourcePosition(
            sourceID: primaryImport.source.id,
            locator: Locator(
                sourceID: primaryImport.source.id,
                snapshotID: primaryImport.snapshot.id,
                adapterID: "markdown-text",
                payload: ["relativePath": "primary.md"],
                structuralPath: nil,
                textQuote: nil,
                fingerprint: primaryImport.snapshot.digest
            ),
            updatedAt: .now,
            progressFraction: 0.8,
            granularity: .text,
            displayLabel: "80%"
        )
        try database.saveReadingProgress(progress, spaceID: spaceID)
        try model.reloadLibraryState()

        // Both sources default to .primary: (0.8 + 0.0) / 2 = 0.4
        XCTAssertEqual(model.sourceRole(for: primaryImport.source.id, in: spaceID), .primary)
        XCTAssertEqual(model.sourceRole(for: referenceImport.source.id, in: spaceID), .primary)
        XCTAssertEqual(model.progressFraction(for: spaceID), 0.4, accuracy: 0.001)

        // Marking the second source as .reference excludes it from diluting primary progress
        model.setSourceRole(.reference, for: referenceImport.source.id, in: spaceID)
        XCTAssertEqual(model.sourceRole(for: referenceImport.source.id, in: spaceID), .reference)
        XCTAssertEqual(model.progressFraction(for: spaceID), 0.8, accuracy: 0.001)

        let persisted = try database.fetchReadingProgress(spaceID: spaceID)
        XCTAssertEqual(persisted.role(for: referenceImport.source.id), .reference)
        XCTAssertEqual(persisted.role(for: primaryImport.source.id), .primary)
    }

    // MARK: - Helpers

    private func makeTemporaryRoot(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneReaderTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBootstrappedModel(root: URL) async throws -> AppModel {
        let suiteName = "OneReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library", isDirectory: true),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }
        return model
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
