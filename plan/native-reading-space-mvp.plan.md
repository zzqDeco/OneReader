# Native Reading-Space MVP

Status: Delivered

Branch: `feature/reading-space-mvp`

## Summary

Deliver a runnable native macOS OneReader slice that demonstrates the core
architecture against both a repository-organized book and a PDF. The slice must
prove source revisions, evidence-backed reading units, goal-specific routes,
native rendering, and persistent progress before introducing an AI provider.

## Scope

- Bootstrap a Swift Package executable using SwiftUI and PDFKit.
- Load the public `xiaolai/time-as-a-friend` repository through GitHub.
- Parse its README table of contents into repository observations.
- Load its public third-edition PDF on demand and support local PDF selection.
- Generate evidence-backed reading units through `SemanticMapping`.
- Project quick, systematic, and review reading plans.
- Render Markdown, native PDF, and comparison presentations.
- Persist completion and current location locally.
- Add domain/parser/persistence tests, app packaging, CI, release workflow,
  current-state documentation, and source notes.

## Non-goals

- Hosted or local LLM provider integration
- OCR
- private GitHub authentication
- local Git worktree ingestion
- annotations or cloud synchronization
- App Store sandboxing, signing, or notarization
- perfect GitHub-Flavored Markdown/HTML compatibility

## Implementation

### Domain

Define `Source`, `SourceSnapshot`, `Locator`, `Observation`, `ReadingUnit`,
`ReadingGraph`, `ReadingPlan`, and `ReadingProgress` as Codable value types.
Use stable source-derived unit identifiers and version graph/plan artifacts.

### Source drivers

`GitHubBookSource` resolves a public URL, default branch, commit SHA, README
table of contents, and raw Markdown. `PDFBookSource` loads bytes, hashes them,
creates a PDFKit document, and emits outline/page-group descriptors.

### Semantic mapping

Define a protocol returning a reading graph. The MVP implementation is
deterministic and uses repository TOC/PDF outline structure. It keeps the source
driver free of semantic sequencing and provides a replaceable seam for later AI
work.

### Reader

Use a native sidebar plus central reading surface and inspector. Render
repository Markdown with reading-oriented SwiftUI blocks. Wrap `PDFView` through
`NSViewRepresentable`. Provide source, PDF, and side-by-side presentations where
evidence allows them.

### Progress

Write versioned JSON atomically under Application Support. Track active plan
goal, selected unit, completed units, and source positions. Fail closed for an
unsupported schema version.

## Test plan

- GitHub URL and README TOC parser tests
- graph evidence and stable-order tests
- quick/systematic/review planner tests
- locator/revision Codable tests
- progress round-trip and unsupported-version tests
- `swift test`
- release build
- documentation-index validation
- unsigned app packaging
- wide/compact and light/dark native visual QA
- live repository Markdown and PDF navigation acceptance

## Assumptions

- The GitHub demonstration remains public.
- GitHub unauthenticated API limits are sufficient for one lazy demo session.
- The public PDF remains available at its repository raw URL.
- macOS 14 is the minimum deployment target.
- A deterministic mapper is acceptable for validating the architecture; AI
  provider design is a separate privacy- and cost-sensitive plan.

## Delivery checklist

- [x] Domain contracts implemented and tested
- [x] GitHub book source implemented and tested
- [x] PDF source implemented and tested
- [x] Native workspace and comparison reader implemented
- [x] Progress persists across relaunch
- [x] CI and release workflows added
- [x] Local validation bundle passes
- [x] Native visual and interaction QA passes
- [x] Stable behavior absorbed into `doc/`
- [x] Status changed to Delivered

## Verification evidence

Verified on 2026-07-23:

- resolved the live `xiaolai/time-as-a-friend` `master` revision to
  `ba8305d` and rendered chapter Markdown lazily;
- loaded the public third-edition PDF as a 306-page PDFKit document with
  digest prefix `5ccd09a`;
- navigated a Repo/PDF comparison from Chapter 1 to Chapter 2 and confirmed
  the PDF locator advanced from page 22 to page 35;
- completed Chapter 1, relaunched the app, and recovered Chapter 2 as current
  with `1/11` progress;
- changed the reading goal to quick overview and observed a different stable
  route;
- passed 12 Swift tests, including an in-memory local PDF inspection test;
- passed release compilation, documentation indexing, app packaging, and
  whitespace validation;
- checked the packaged app at 1440 × 900 and 900 × 650 in light and dark
  appearances. Compact mode preserves the source sidebar and reader while
  hiding the auxiliary route inspector.
