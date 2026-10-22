# Progressive Evidence Desk (渐进式证据研读台)

Status: Active

## Goal

Unify OneReader's four product stages—Capture/Import, Reading Space Organization,
Multi-Surface Reading + Highlighting, and Evidence-Grounded Agent Assistance—into
a cohesive **Progressive Evidence Desk (渐进式证据研读台)** loop without adding a
new database schema migration or weakening any citation, snapshot, or untrusted-input
invariants.

## Product loop

1. **Desk Lifecycle & Cross-Space Notes**
   - Spaces and Sources can be renamed directly from Library and Reader surfaces.
   - Sources in a multi-source Reading Space can be detached from the current space
     without deleting the underlying managed Source or its annotations, or removed
     from the Library entirely.
   - Reading Spaces can be deleted cleanly (removing exclusively owned Sources while
     detaching shared Sources).
   - Sources in a Reading Space can be marked as `primary` (主读材料) or `reference`
     (参考附件) inside `ReadingProgress.sourceRoles` so reference materials do not
     dilute reading progress percentages.
   - Space annotation queries (`fetchAnnotations(spaceID:sourceID:)`) include
     annotations whose `source_id` belongs to `space_sources` for that space so
     notes created in the Capture Inbox remain visible after organizing into a
     target Reading Space.

2. **Unified Library Search & Queue Consolidation**
   - `LibraryHomeView` upgrades its search bar into a unified Library search across:
     - matching `ReadingSpace`s (by title or source display name),
     - full-text indexed `Observation` hits (`database.searchObservations`), and
     - private Notes/Highlights hits (`database.notesPage`).
   - Selecting a full-text hit or note hit from `LibraryHomeView` opens the
     appropriate `ReadingSpace` and navigates directly to its anchored `Locator`.
   - `LibraryHomeView` consolidates capture and pending-import feedback and exposes
     direct context-menu actions (`重命名空间…`, `删除空间…`) on space cards.

3. **Inline Canvas Highlights & Contextual Selection Bar**
   - Active non-orphaned `Annotation` highlights for the current Source are passed
     into `AdapterPresentationView` on macOS and iOS and rendered non-destructively
     in-place across:
     - Native Markdown / Text / Code (`NSTextView` / `UITextView`),
     - PDF (`PDFKit`), and
     - Controlled WebKit (`WKWebView` for EPUB / HTML / WebSnapshot).
   - `ReaderSurfaceView` presents a contextual selection action bar when
     `model.currentSelection != nil` with one-tap actions for **高亮**, **记笔记**,
     and **问此段**.

4. **Intent-Driven Reading Agent & QA-to-Note Loop**
   - `ReaderNavigationSidebar.routeView` lets the reader pick a `ReadingGoal`
     (`overview`, `systematic`, `review`, or custom goal text) before launching
     route generation, with a fast path that skips redundant `routeAdapters` runs
     when the deterministic `AdapterPlan.confidence >= 0.85`.
   - `ReaderInspectorView.askView` displays persisted `evidenceQAHistory` per Space
     from completed `answerWithEvidence` runs and lets the user save any verified
     answer and citation as a grounded `Annotation` (**存为笔记**).
   - `AnnotationAnchorState` badges in `ReaderInspectorView` are localized into
     clear Chinese reader labels (`已对齐新版本`, `原文已变动`).

## Verification

- `swift test`
- `swift build --configuration release`
- `python3 scripts/check-doc-index.py`
- `python3 scripts/check-apple-platform-metadata.py`
- `scripts/check-xcode-project.sh`
- `scripts/build-ios-simulator.sh`
- `scripts/package-app.sh`
- `git diff --check`
