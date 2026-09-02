# v0.3 Acceptance

## Automated gates

| Gate | Command | Required |
| --- | --- | --- |
| Dependency lock | `python3 scripts/check-dependency-lock.py` | Yes |
| Domain, adapter, runtime, persistence, and app-model tests | `swift test` | Yes |
| Release compilation | `swift build --configuration release` | Yes |
| Documentation index | `python3 scripts/check-doc-index.py` | Yes |
| Apple target and icon metadata | `python3 scripts/check-apple-platform-metadata.py` | Yes |
| Generated Xcode project drift | `scripts/check-xcode-project.sh` | Yes |
| Generic iPhone/iPad Simulator SDK compilation (no device boot) | `scripts/build-ios-simulator.sh` | Yes |
| Sandboxed native app | `scripts/package-app.sh` | Yes |
| Signature and entitlements | `codesign --verify` plus Sandbox entitlement inspection | Yes |
| Release policy fixtures | `scripts/test-release-gates.sh` and `scripts/test-entitlement-gate.sh` | Yes |
| Whitespace | `git diff --check` | Yes |

`scripts/validate-native.sh` runs this same path locally and in hosted CI,
including the shared dependency-lock digest before and after both native builds.
Provider tests use fake models and injected URL protocols; CI receives no real
model secret.

## iPhone physical-device record

On 2026-09-01 and 2026-09-02, implementation commit `3572f91` was built,
signed, installed, and launched on a wired iPhone 13 Pro Max running iOS 27.0
beta (build `24A5424a`). The device was paired, booted, Developer Mode was
enabled, and Developer Disk Image services were available.

- Every Simulator device instance was deleted before physical-device testing.
  Installed Simulator runtimes remain available to Xcode, but the generic SDK
  compilation gate did not create or boot a Simulator device.
- Xcode produced an arm64 Debug application with Bundle ID
  `io.github.zzqDeco.OneReader`, version 0.3.0 (3), and an automatically managed
  development signature. The personal development Team is supplied only on the
  local command line and is not stored in the project.
- The first install attempt reached the device and was rejected only because a
  free development profile already tracked three applications. The removable
  `PixSigilUITests-Runner` test artifact was uninstalled; PixSigil, EasyNote,
  and their data were not removed. Xcode recreates that Runner on the next
  PixSigil UI-test run.
- OneReader then installed successfully. The first launch request was rejected
  while the device was locked; after unlock, the same signed application
  launched successfully and its OneReader process remained present across
  repeated device-process checks several minutes apart.
- ScreenCaptureKit could not start the local device-view capture, so no physical
  screenshot is claimed. This record proves physical build, signing, install,
  launch, and process survival; it does not substitute a screenshot for visual
  layout acceptance.
- No physical iPad was connected. iPadOS evidence for this delivery is limited
  to the shared universal target, device-family metadata, complete iPad icon
  slots, and successful generic iPhone/iPad SDK compilation. A regular-width
  physical iPad walkthrough remains explicitly unrecorded.

On 2026-09-02, four representative inputs were then exercised through the
installed iPhone application's Open In URL path: a generated Markdown file, a
generated sanitized-HTML fixture, a public research PDF, and a generated RTF
file for the unknown-file fallback. Device-container inspection after the app
finished each import proved four immutable managed payloads and four committed
Source/Snapshot/AdapterPlan triples:

- Markdown selected `onereader.markdown` at confidence 0.98 and published two
  search documents;
- HTML selected `onereader.html` at confidence 0.98 and published one search
  document;
- PDF selected `onereader.pdf` at confidence 1.0 and published nine page search
  documents;
- RTF selected `onereader.quicklook` at confidence 0.1 and deliberately
  published no Observation or search document.

The final branch head was rebuilt, signed, installed over that Library, and
launched again on the same connected iPhone. The exact commit is captured in
the local handoff and Sol max review dispatch; no source file or Team identifier
is used as mutable evidence. The four persisted Sources remained in the
managed Library after replacement installation. Four Reading History rows and
four durable source-position records carry Markdown heading, sanitized DOM,
PDF page, and Quick Look Locators respectively, proving each import progressed
through presentation selection and position publication. This is device
evidence for import, managed snapshots, deterministic routing, indexing
capability gates, presentation entry, application replacement, relaunch, and
persistence. Screen-level PDF/text pixels, selection and annotation gestures,
compact-layout pixels, and physical iPad behavior remain unclaimed.

## Fixture and contract coverage

Generated, non-copyrighted fixtures exercise PDF, EPUB, Markdown, text, code,
HTML, directories, web snapshots, public GitHub archives, remote documents,
and unknown-file Quick Look routing. Adapter tests cover every declared
capability and current/relocated Locator behavior. Security cases cover ZIP
traversal, symlinks, expansion limits, Unicode/case collisions, HTML active
content, private-address and plain-HTTP rejection, redirect/origin boundaries,
bounded text loading, and local resource escape.
Controlled WebKit resource tests additionally cover MIME denial, the 32 MiB
ceiling, chunk bounds, symlink escape, and stop-before-next-chunk cancellation.

Runtime tests use fake model sessions to cover the five task shapes, exact
Snapshot manifests, low-confidence waiting, Provider disclosure, budgets,
four-read concurrency, ordered reinjection, cancellation, late output,
interruption/resume, Artifact spill, four-stage projection, endpoint isolation,
stream limits, redaction, and transactional structured-output validation.
Routing tests require one explicit Source/Snapshot target, resume from the next
Source checkpoint after confirmation/dismissal, and prove that a terminated UI
stream cannot cancel a replacement Run. Recovery tests persist pipeline
provenance and prove disclosure/interrupted evidence answers stop after the
answer, scout/materialize resume at the next phase, delayed explicit
cancellation is Run-ID scoped, and an interrupted Run can be abandoned.

Persistence and workspace tests cover atomic import, digest deduplication,
legacy backup, FTS rebuild and Chinese substring fallback, annotation and
progress round trips, Quick Look capability gating, preferences, index-job
deduplication, durable position restore, Source refresh relocation, platform
import-purpose selection, injected security-scope balancing, the macOS bookmark
database/renewal contract, pending frozen-plan adoption, Space generation
isolation, and crash-safe Agent state. They do not claim a document-provider
bookmark lifecycle walkthrough on physical iOS hardware.
Schema-v9 tests prove ordinary evidence Observations remain outside search,
late superseded-plan publication loses the active-plan CAS, directory indexes
expand every PDF page and EPUB spine item, repeated Markdown text maps to exact
source ranges, and WebKit emits no callback after stop returns. A real v8
fixture proves bootstrap rebuilds global search without opening the migrated
Space. Markdown mapping fixtures exclude link destinations, raw HTML, inline
backtick delimiters, code fences, and repeated language identifiers while
preserving escapes, entities, and UTF-8-to-UTF-16 offsets. Normalized multiline
code spans and indented fences prove incomplete or syntax-anchored leaf maps are
discarded wholesale; left/right cross-leaf selections prove adjacent mapped
spaces cannot become partial Locators. AppModel coverage proves a Provider
mutation immediately removes an invalidated interrupted Run from Inspector state;
nested HTML fixtures prove sanitizer and presentation use one Snapshot resource root.
Removal recovery coverage forces both the metadata transaction and immediate
restore to fail, then proves the next Library initialization restores the
managed container from a durable journal. PDF anchor coverage rejects malformed
rectangles, clips valid geometry to the page, and gives a recorded page rectangle
priority over ambiguous quote-only fallback. Mobile source-action coverage
exposes explicit HTTP(S) origins but never presents a stale document-provider
file URL as an openable original.

## macOS v0.2 baseline record

On 2026-09-01 the ad-hoc signed Sandbox app was exercised with a managed
snapshot of `xiaolai/time-as-a-friend` and its included PDFs. Local acceptance
material remains outside Git:

- the public GitHub repository imported as one Source and one Reading Space;
  Processing completed with no duplicate index job left behind;
- the directory tree composed Markdown, image, and PDF child adapters; Chinese
  Markdown rendered in a selectable native surface;
- the included `first-edition.pdf` opened through PDFKit in both wide and
  900 x 650 windows;
- searching `时间管理` returned accessible rows with Source and context, and a
  result jumped back to the anchored Markdown document;
- a PDF bookmark, Markdown exact-quote highlight, and anchored note survived
  application relaunch with `current` anchor state;
- 1440 x 900 and 900 x 650 layouts were exercised with the Inspector visible;
  the compact Inspector used its overlay presentation without an AppKit
  constraint loop;
- the deep reading theme and 120 percent PDF scale were changed through native
  Settings; the accessibility tree exposed Library, navigation, search,
  Inspector, annotation, and toolbar labels.

No model was configured during this walkthrough. Reading, search, annotation,
history, and restart recovery therefore provide explicit no-Provider evidence.

## Release-only acceptance

Release-reference fixtures prove an annotated `vX.Y.Z` tag must be exactly the
checkout and `origin/main` tip, while lightweight and behind-tip tags fail.
Entitlement fixtures prove Sandbox, network client, and user-selected read-only
access are required, and user-selected read-write access fails. A local dry run
produced a valid DMG and ZIP whose SHA-256 sidecars and manifest verified; the
manifest records database schema 9, adapter schema 1, Agent runtime schema 5,
ad-hoc signing, Sandbox, and unnotarized state.

The workflow contract makes manual dispatch artifact-only and refuses to
overwrite an existing GitHub Release. No live tag, remote release, or branch
protection was created because this repository currently has no remote. The
Developer Preview remains explicitly ad-hoc signed and not notarized.
