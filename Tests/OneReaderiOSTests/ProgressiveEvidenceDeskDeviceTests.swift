#if os(iOS)
import CoreText
import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class ProgressiveEvidenceDeskDeviceTests: XCTestCase {
    func testInlineMarkdownCodeAndPDFHighlightsRenderInLiveDeviceWindowLightAndDark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-DeviceHighlight-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownText = """
        # Progressive Evidence Desk

        First paragraph with **verifiable inline evidence** inside the reader canvas.

        Second paragraph for context verification.
        """
        let markdownLocator = Locator(
            sourceID: "source-md",
            snapshotID: "snap-md",
            adapterID: "onereader.markdown",
            payload: ["path": "desk.md"]
        )
        let rawRange = (markdownText as NSString).range(of: "**verifiable inline evidence**")
        let markdownHighlight = Annotation(
            id: "hl-device-md",
            spaceID: "space-device",
            sourceID: "source-md",
            snapshotID: "snap-md",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-md",
                snapshotID: "snap-md",
                adapterID: "onereader.markdown",
                payload: [
                    "path": "desk.md",
                    "startUTF16": String(rawRange.location),
                    "endUTF16": String(NSMaxRange(rawRange)),
                ],
                textQuote: TextQuote(
                    prefix: "with ",
                    exact: "**verifiable inline evidence**",
                    suffix: " inside"
                )
            ),
            anchorState: .current,
            selectedText: "verifiable inline evidence",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let markdownDoc = PresentationDocument(
            id: "doc-md",
            surface: .nativeMarkdown,
            locator: markdownLocator,
            title: "Desk Markdown",
            mediaType: "text/markdown",
            content: markdownText,
            contentURL: nil,
            baseURL: nil,
            limitations: []
        )

        let window = makeLiveWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let host = UIHostingController(
            rootView: AnyView(
                AdapterPresentationView(
                    document: markdownDoc,
                    captureTargetID: UUID(),
                    preferences: ReaderPreferences(),
                    onSelectionChange: { _ in },
                    onPositionChange: { _ in },
                    highlights: [markdownHighlight]
                )
            )
        )
        window.rootViewController = host
        window.makeKeyAndVisible()

        for style in [UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark] {
            window.overrideUserInterfaceStyle = style
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()

            try await waitUntil {
                guard let textView = self.findTextView(in: host.view),
                      let attr = textView.attributedText,
                      attr.length > 0 else {
                    return false
                }
                let renderedRange = (attr.string as NSString).range(of: "verifiable inline evidence")
                guard renderedRange.location != NSNotFound else { return false }
                return attr.attribute(.backgroundColor, at: renderedRange.location, effectiveRange: nil) != nil
            }
        }

        // Now verify PDF inline highlight annotation in live PDFView on device
        let pdfURL = root.appendingPathComponent("device-evidence.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 320)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
        let pdfContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        pdfContext.beginPDFPage(nil)
        let ctLine = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "PDF canvas highlight anchor",
                attributes: [.font: UIFont.systemFont(ofSize: 20)]
            )
        )
        pdfContext.textPosition = CGPoint(x: 32, y: 200)
        CTLineDraw(ctLine, pdfContext)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        let pdfLocator = Locator(
            sourceID: "source-pdf",
            snapshotID: "snap-pdf",
            adapterID: PDFAdapter.id,
            payload: ["pageIndex": "0"]
        )
        let pdfHighlight = Annotation(
            id: "hl-device-pdf",
            spaceID: "space-device",
            sourceID: "source-pdf",
            snapshotID: "snap-pdf",
            kind: .highlight,
            locator: Locator(
                sourceID: "source-pdf",
                snapshotID: "snap-pdf",
                adapterID: PDFAdapter.id,
                payload: [
                    "pageIndex": "0",
                    "rect": "32.0,190.0,220.0,28.0",
                ],
                textQuote: TextQuote(
                    prefix: nil,
                    exact: "PDF canvas highlight anchor",
                    suffix: nil
                )
            ),
            anchorState: .current,
            selectedText: "PDF canvas highlight anchor",
            note: nil,
            color: "yellow",
            createdAt: .now,
            updatedAt: .now
        )
        let pdfDoc = PresentationDocument(
            id: "doc-pdf",
            surface: .pdfKit,
            locator: pdfLocator,
            title: "Device PDF",
            mediaType: "application/pdf",
            content: nil,
            contentURL: pdfURL,
            baseURL: nil,
            limitations: []
        )

        host.rootView = AnyView(
            AdapterPresentationView(
                document: pdfDoc,
                captureTargetID: UUID(),
                preferences: ReaderPreferences(),
                onSelectionChange: { _ in },
                onPositionChange: { _ in },
                highlights: [pdfHighlight]
            )
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        try await waitUntil {
            guard let pdfView = self.findPDFView(in: host.view),
                  let page = pdfView.document?.page(at: 0) else {
                return false
            }
            return page.annotations.contains {
                $0.userName == InlineHighlightSupport.pdfAnnotationUserName
            }
        }
    }

    func testEndToEndProgressiveEvidenceDeskWorkspaceInCompactAndRegularLightAndDark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OneReader-DeviceWorkspace-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primaryURL = root.appendingPathComponent("PrimaryPaper.md")
        let referenceURL = root.appendingPathComponent("ReferenceGlossary.md")
        let primaryMarkdown = """
        # Architecture Overview

        Progressive Evidence Desk binds every reading claim to a deterministic source fragment.

        ## Core Invariant

        Changed revisions never silently reuse a positional locator as if it were current.
        """
        let referenceMarkdown = """
        # Terminology Glossary

        Reference appendix for quick lookup without diluting primary reading progress.
        """
        try Data(primaryMarkdown.utf8).write(to: primaryURL)
        try Data(referenceMarkdown.utf8).write(to: referenceURL)

        let suiteName = "OneReaderDeviceTests.\(UUID().uuidString)"
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
        model.renameSpace(spaceID, title: "渐进式证据研读台验收")
        model.renameSource(primaryImport.source.id, displayName: "核心架构论文.md")
        XCTAssertEqual(model.spaces.first?.title, "渐进式证据研读台验收")
        XCTAssertEqual(model.source(id: primaryImport.source.id)?.displayName, "核心架构论文.md")

        var progress = try database.fetchReadingProgress(spaceID: spaceID)
        progress.sourcePositions[primaryImport.source.id] = SourcePosition(
            sourceID: primaryImport.source.id,
            locator: Locator(
                sourceID: primaryImport.source.id,
                snapshotID: primaryImport.snapshot.id,
                adapterID: MarkdownAdapter.id,
                payload: ["path": "PrimaryPaper.md"],
                fingerprint: primaryImport.snapshot.digest
            ),
            updatedAt: .now,
            progressFraction: 0.75,
            granularity: .text,
            displayLabel: "75%"
        )
        try database.saveReadingProgress(progress, spaceID: spaceID)
        try model.reloadLibraryState()
        XCTAssertEqual(model.progressFraction(for: spaceID), 0.375, accuracy: 0.001)

        model.setSourceRole(.reference, for: referenceImport.source.id, in: spaceID)
        XCTAssertEqual(model.sourceRole(for: referenceImport.source.id, in: spaceID), .reference)
        XCTAssertEqual(model.progressFraction(for: spaceID), 0.75, accuracy: 0.001)

        // Mount full WorkspaceView in a live UIWindow on the device
        let window = makeLiveWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = UIHostingController(
            rootView: AnyView(WorkspaceView().environmentObject(model))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        // Open Reader Workspace first so AdapterCoordinator indexes full-text Observations
        // and we verify Pillar 3 (Contextual Selection Bar + Inline Highlights)
        // and Pillar 4 (Intent-Driven ReadingGoal + Ask Selection + Save QA as Note)
        model.openSpace(spaceID)
        try await waitUntil {
            model.isReadingWorkspaceOpen
                && model.selectedSpaceID == spaceID
                && model.presentationDocument != nil
                && self.findTextView(in: host.view) != nil
        }

        model.selectReadingGoal(.quickOverview)
        XCTAssertEqual(model.selectedReadingGoal, .quickOverview)
        XCTAssertEqual(try database.fetchReadingProgress(spaceID: spaceID).activeGoal, .quickOverview)

        let quoteText = "deterministic source fragment"
        let quoteRange = (primaryMarkdown as NSString).range(of: quoteText)
        XCTAssertNotEqual(quoteRange.location, NSNotFound)

        let selectionLocator = Locator(
            sourceID: primaryImport.source.id,
            snapshotID: primaryImport.snapshot.id,
            adapterID: MarkdownAdapter.id,
            payload: [
                "path": "PrimaryPaper.md",
                "startUTF16": String(quoteRange.location),
                "endUTF16": String(NSMaxRange(quoteRange)),
            ],
            structuralPath: "Architecture Overview",
            textQuote: TextQuote(
                prefix: "every reading claim to a ",
                exact: quoteText,
                suffix: "."
            ),
            fingerprint: primaryImport.snapshot.digest
        )

        // Create inline highlight & verify live UITextView attribute update
        model.currentSelection = ReaderSelection(
            text: quoteText,
            locator: selectionLocator
        )
        model.addHighlight()
        XCTAssertEqual(model.currentSourceHighlights.count, 1)
        try await waitUntil {
            guard let textView = self.findTextView(in: host.view),
                  let attr = textView.attributedText else {
                return false
            }
            let r = (attr.string as NSString).range(of: quoteText)
            guard r.location != NSNotFound else { return false }
            return attr.attribute(.backgroundColor, at: r.location, effectiveRange: nil) != nil
        }

        // Re-select so both the inline highlight AND the Contextual Selection Bar are visible
        model.currentSelection = ReaderSelection(
            text: quoteText,
            locator: selectionLocator
        )
        window.overrideUserInterfaceStyle = .light
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        attachSnapshot(of: window, named: "device-reader-selection-bar-compact-light")

        window.overrideUserInterfaceStyle = .dark
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        attachSnapshot(of: window, named: "device-reader-selection-bar-compact-dark")

        // Trigger "Ask about current selection" (问此段)
        model.askAboutCurrentSelection()
        XCTAssertEqual(model.inspectorTab, .ask)
        XCTAssertTrue(model.isInspectorPresented)

        // Save an Evidence QA turn as a durable Note (QA-to-Note closed loop)
        let qa = CompletedEvidenceQA(
            id: "qa-device-1",
            runID: "run-device-1",
            spaceID: spaceID,
            question: "为什么修订后不能静默复用旧位置？",
            answer: EvidenceAnswer(
                schemaVersion: EvidenceAnswer.currentSchemaVersion,
                answer: "因为快照变更后行号或偏移可能漂移，必须先通过引用重定位确认证据仍然有效。",
                citations: [
                    EvidenceCitation(
                        id: "cit-device-1",
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
        XCTAssertTrue(
            model.annotations.contains {
                $0.kind == .note
                    && ($0.note?.contains("为什么修订后不能静默复用旧位置") == true)
                    && $0.selectedText == quoteText
            }
        )

        // Snapshot Regular width (1024x768, iPad regular size class) in Light & Dark modes
        model.isInspectorPresented = false
        model.currentSelection = ReaderSelection(
            text: quoteText,
            locator: selectionLocator
        )
        try await Task.sleep(for: .milliseconds(100))
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        host.traitOverrides.horizontalSizeClass = .regular
        host.rootView = AnyView(
            WorkspaceView()
                .environment(\.horizontalSizeClass, .regular)
                .environmentObject(model)
        )
        host.view.frame = window.bounds
        window.overrideUserInterfaceStyle = .light
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        attachSnapshot(of: window, named: "device-reader-workspace-regular-light")

        window.overrideUserInterfaceStyle = .dark
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        attachSnapshot(of: window, named: "device-reader-workspace-regular-dark")

        // Pillar 2: Return to Library in Compact size class and verify Unified Library Search
        // (matching contentHits + noteEntries simultaneously in Light & Dark)
        model.closeReadingWorkspace()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.traitOverrides.horizontalSizeClass = .compact
        host.rootView = AnyView(
            WorkspaceView()
                .environment(\.horizontalSizeClass, .compact)
                .environmentObject(model)
        )
        host.view.frame = window.bounds
        model.librarySearchText = "deterministic"
        model.performUnifiedLibrarySearch()
        try await waitUntil {
            model.hasActiveLibrarySearch
                && !model.isUnifiedSearching
                && !model.unifiedSearchResults.contentHits.isEmpty
                && !model.unifiedSearchResults.noteEntries.isEmpty
        }

        window.overrideUserInterfaceStyle = .light
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        attachSnapshot(of: window, named: "device-library-unified-search-compact-light")

        window.overrideUserInterfaceStyle = .dark
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        attachSnapshot(of: window, named: "device-library-unified-search-compact-dark")
    }

    // MARK: - Helpers

    private func makeLiveWindow(frame: CGRect) -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        return UIWindow(frame: frame)
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func findPDFView(in view: UIView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }

    private func attachSnapshot(of window: UIWindow, named name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for live device UI condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
