# Progressive Evidence Desk (渐进式证据研读台)

Status: Active

## PR #35 review follow-up

The merge candidate is being revised after independent review of `88581b6`.

- [x] Keep historical Q&A citations on their original Snapshot and classify saved notes against the latest revision.
- [x] Present lifecycle dialogs from the persistent workspace, including compact navigation sheets.
- [x] Disambiguate repeated PDF quotations using same-Snapshot selection rectangles; reject ambiguous cross-revision matches.
- [x] Preserve the reading goal and adapter-routing policy across disclosure, interruption, and candidate continuation.
- [x] Render HTML/EPUB highlights across inline text nodes without changing document structure.
- [ ] Run focused regressions, hosted native validation, and Sol max review on the updated commit.

2026-10-23 repair evidence: all 402 macOS tests pass (19 focused regressions), including live
workspace alerts, PDF duplicate quotations, actual WKWebView cross-node marks,
historical Q&A navigation/note classification, remote disclosure, interrupted
scout/materialize and candidate-dismissal continuation. Documentation, dependency
lock, Apple metadata and generated Xcode project checks also pass. The compact iPhone
lifecycle UI regression passes on physical iPhone hardware with exact name checks,
and Sol max cleared the repair and workspace-expression split. Release packaging
and exact-head CI must be repeated after the final commit;
the original acceptance below is baseline evidence, not a claim about this repair.

The second review found two repair side effects, now covered by the repeated
402-test pass: saving historical QA preserves the currently adopted AdapterPlan
and active FTS projection, and a relocated PDF annotation may use its original
rectangle when previewing that identical immutable Snapshot (never a newer one).
Physical UI testing also checks actual rename/save and cancel-deletion actions;
XCTest refocuses the field after text injection and waits for the software keyboard
before locating Save, so keyboard-driven alert movement precedes the action tap.
Rename text is cleared from its end and checked exactly, including the source extension;
a substring match alone is not sufficient acceptance evidence.

Hosted Xcode 26.6 exposed a type-checking timeout in the expanded workspace modifier
chain. Split lifecycle, common presentation, interaction, and platform presentation
expressions without changing their order, dialog ownership, or state lifetime;
repeat the native workspace/phone regressions and exact-head CI after this repair.
The split passes all 402 local tests and the physical iPhone lifecycle regression;
test screenshots confirm exact Source/Space names and cancellation preserves the Space.

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

- `swift test` (393/393 tests passing, including `ProgressiveEvidenceDeskMacAcceptanceTests`)
- `swift build --configuration release`
- `python3 scripts/check-doc-index.py`
- `python3 scripts/check-apple-platform-metadata.py`
- `scripts/check-xcode-project.sh`
- `scripts/build-ios-simulator.sh`
- `scripts/package-app.sh`
- `git diff --check`

## Real-Device & Multi-Platform Native Acceptance

- **Physical iPhone (`赵子谦的iPhone`, `iPhone 18 Pro Max`, UDID `00008160-0006456A0CD0000A`, iOS 26.1+)**:
  - Executed `OneReader-iOSLayoutTests` (33/33 tests passing on hardware, including `ProgressiveEvidenceDeskDeviceTests`, `LocalOCRDeviceTests`, `NativePDFSelectionDeviceTests`, `OCRPresentationTests`, `PDFZoomControllerTests`, and `ReaderTextViewportTests`) in isolated test bundle `io.github.zzqDeco.OneReader.ImportZoomAcceptance`.
  - Verified live `UIWindow` rendering and exported hardware `XCTAttachment` screenshots across:
    - **iPhone Compact (`390x844`, Light & Dark)**: Inline `UITextView` & `PDFView` canvas highlights, Contextual Selection Bar (`reader-selection-bar`), `问此段` inspector sheet, and Unified Library Search (`正文命中` + `笔记与高亮命中`).
    - **iPad Regular (`1024x768`, `.regular` horizontalSizeClass, Light & Dark)**: Persistent split navigation sidebar, inline canvas highlight, and reader footer bar.
- **Native macOS (`OneReader-macOS`, `NSWindow` live hosting)**:
  - Executed `ProgressiveEvidenceDeskMacAcceptanceTests` across **Wide (`1440x900`)** and **Narrow (`900x650`)** frames in both **Light (`.aqua`)** and **Dark (`.darkAqua`)** appearances, verifying 3-column reader workspace, inline `NSTextView` highlight attributes, Contextual Selection Bar, QA-to-Note persistence, and Unified Library Search.
