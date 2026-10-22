#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import OneReader

@MainActor
final class ProgressiveEvidenceDeskMacAcceptanceTests: XCTestCase {
    func testMacLiveWindowAcceptanceNarrowAndWideLightAndDark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-MacAcceptance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primaryURL = root.appendingPathComponent("ArchitecturePaper.md")
        let referenceURL = root.appendingPathComponent("ReferenceAppendix.md")
        let primaryMarkdown = """
        # Progressive Evidence Desk on macOS

        Every claim in the synthesis note is anchored to a **deterministic source fragment** in the primary document.

        ## Revision Invariant

        Changed revisions never silently reuse a positional locator as if it were current.
        """
        let referenceMarkdown = """
        # Reference Appendix

        Supplementary glossary that does not dilute primary reading progress.
        """
        try Data(primaryMarkdown.utf8).write(to: primaryURL)
        try Data(referenceMarkdown.utf8).write(to: referenceURL)

        let suiteName = "OneReaderMacAcceptance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            libraryRootURL: root.appendingPathComponent("Library", isDirectory: true),
            defaults: defaults,
            secretStore: InMemoryProviderSecretStore()
        )
        try await waitUntil { model.isBootstrapComplete }

        let library = try XCTUnwrap(model.managedLibrary)
        let database = try XCTUnwrap(model.database)

        let primaryImport = try await library.importLocalSource(at: primaryURL)
        let spaceID = primaryImport.space.id
        let referenceImport = try await library.importLocalSource(at: referenceURL, intoSpaceID: spaceID)
        try model.reloadLibraryState()

        // Pillar 1: Rename Space & Source + Reference Role Progress Weighting
        model.renameSpace(spaceID, title: "macOS 渐进式证据研读台")
        model.renameSource(primaryImport.source.id, displayName: "架构核心论文.md")
        model.setSourceRole(.reference, for: referenceImport.source.id, in: spaceID)

        var progress = try database.fetchReadingProgress(spaceID: spaceID)
        progress.sourcePositions[primaryImport.source.id] = SourcePosition(
            sourceID: primaryImport.source.id,
            locator: Locator(
                sourceID: primaryImport.source.id,
                snapshotID: primaryImport.snapshot.id,
                adapterID: MarkdownAdapter.id,
                payload: ["path": "ArchitecturePaper.md"],
                fingerprint: primaryImport.snapshot.digest
            ),
            updatedAt: .now,
            progressFraction: 0.85,
            granularity: .text,
            displayLabel: "85%"
        )
        try database.saveReadingProgress(progress, spaceID: spaceID)
        try model.reloadLibraryState()
        XCTAssertEqual(model.progressFraction(for: spaceID), 0.85, accuracy: 0.001)

        // Open Reader Workspace first so AdapterCoordinator indexes full-text Observations
        model.openSpace(spaceID)
        let captureTargetID = UUID()
        model.activateReadingPositionCaptureTarget(captureTargetID)
        let host = NSHostingView(
            rootView: AnyView(
                HStack(spacing: 0) {
                    ReaderNavigationSidebar()
                        .frame(width: 230)
                    Divider()
                    ReaderSurfaceView()
                    Divider()
                    ReaderInspectorView()
                        .frame(width: 320)
                }
                .environment(\.readingPositionCaptureTargetID, captureTargetID)
                .environmentObject(model)
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        try await waitUntil {
            model.isReadingWorkspaceOpen
                && model.selectedSpaceID == spaceID
                && model.presentationDocument != nil
                && self.findTextView(in: host) != nil
        }

        model.selectReadingGoal(.quickOverview)
        XCTAssertEqual(model.selectedReadingGoal, .quickOverview)

        let quoteText = "deterministic source fragment"
        let quoteRange = (primaryMarkdown as NSString).range(of: "**deterministic source fragment**")
        let selectionLocator = Locator(
            sourceID: primaryImport.source.id,
            snapshotID: primaryImport.snapshot.id,
            adapterID: MarkdownAdapter.id,
            payload: [
                "path": "ArchitecturePaper.md",
                "startUTF16": String(quoteRange.location),
                "endUTF16": String(NSMaxRange(quoteRange)),
            ],
            structuralPath: "Progressive Evidence Desk on macOS",
            textQuote: TextQuote(
                prefix: "anchored to a ",
                exact: "**deterministic source fragment**",
                suffix: " in the primary"
            ),
            fingerprint: primaryImport.snapshot.digest
        )
        model.currentSelection = ReaderSelection(
            text: quoteText,
            locator: selectionLocator
        )
        model.addHighlight()
        XCTAssertEqual(model.currentSourceHighlights.count, 1)

        try await waitUntil {
            guard let textView = self.findTextView(in: host),
                  let storage = textView.textStorage else {
                return false
            }
            let r = (storage.string as NSString).range(of: quoteText)
            guard r.location != NSNotFound else { return false }
            return storage.attribute(.backgroundColor, at: r.location, effectiveRange: nil) != nil
        }

        // Save QA as Note & keep selection bar visible for screenshot
        let qa = CompletedEvidenceQA(
            id: "qa-mac-1",
            runID: "run-mac-1",
            spaceID: spaceID,
            question: "研读台如何保证结论可溯源？",
            answer: EvidenceAnswer(
                schemaVersion: EvidenceAnswer.currentSchemaVersion,
                answer: "每条结论都绑定不可变快照与原文片段引用，点击即可跳回正文高亮处。",
                citations: [
                    EvidenceCitation(
                        id: "cit-mac-1",
                        fragmentID: nil,
                        sourceID: primaryImport.source.id,
                        snapshotID: primaryImport.snapshot.id,
                        locator: selectionLocator,
                        quote: quoteText
                    ),
                ],
                limitations: []
            )
        )
        model.saveEvidenceQAAsNote(qa)
        model.currentSelection = ReaderSelection(
            text: quoteText,
            locator: selectionLocator
        )
        model.inspectorTab = .annotations
        model.isInspectorPresented = true
        try await Task.sleep(for: .milliseconds(80))

        // Wide (1440x900) Light & Dark
        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 1440, height: 900),
            appearance: .aqua,
            name: "macos-reader-workspace-wide-light.png"
        )
        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 1440, height: 900),
            appearance: .darkAqua,
            name: "macos-reader-workspace-wide-dark.png"
        )

        // Narrow (900x650) Light & Dark
        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 900, height: 650),
            appearance: .aqua,
            name: "macos-reader-workspace-narrow-light.png"
        )
        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 900, height: 650),
            appearance: .darkAqua,
            name: "macos-reader-workspace-narrow-dark.png"
        )

        // Pillar 2: Return to Library and snapshot Unified Library Search (Spaces + ContentHits + Notes)
        model.closeReadingWorkspace()
        host.rootView = AnyView(
            HStack(spacing: 0) {
                LibrarySidebarView()
                    .frame(width: 240)
                Divider()
                LibraryHomeView()
            }
            .environment(\.readingPositionCaptureTargetID, captureTargetID)
            .environmentObject(model)
        )
        model.librarySearchText = "deterministic"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            model.hasActiveLibrarySearch
                && !model.isUnifiedSearching
                && !model.unifiedSearchResults.contentHits.isEmpty
                && !model.unifiedSearchResults.noteEntries.isEmpty
        }

        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 1440, height: 900),
            appearance: .aqua,
            name: "macos-library-unified-search-wide-light.png"
        )
        resizeAndSnapshot(
            window: window,
            host: host,
            size: NSSize(width: 900, height: 650),
            appearance: .darkAqua,
            name: "macos-library-unified-search-narrow-dark.png"
        )
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func resizeAndSnapshot(
        window: NSWindow,
        host: NSView,
        size: NSSize,
        appearance: NSAppearance.Name,
        name: String
    ) {
        window.setContentSize(size)
        window.appearance = NSAppearance(named: appearance)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        let bounds = host.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-MacAcceptance-Screenshots",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? pngData.write(to: outDir.appendingPathComponent(name))
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for live macOS window condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
