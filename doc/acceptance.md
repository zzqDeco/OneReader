# v0.2 Acceptance

## Automated gates

| Gate | Command | Required |
| --- | --- | --- |
| Dependency lock | `python3 scripts/check-dependency-lock.py` | Yes |
| Domain, adapter, runtime, persistence, and app-model tests | `swift test` | Yes |
| Release compilation | `swift build --configuration release` | Yes |
| Documentation index | `python3 scripts/check-doc-index.py` | Yes |
| Sandboxed native app | `scripts/package-app.sh` | Yes |
| Signature and entitlements | `codesign --verify` plus Sandbox entitlement inspection | Yes |
| Release policy fixtures | `scripts/test-release-gates.sh` and `scripts/test-entitlement-gate.sh` | Yes |
| Whitespace | `git diff --check` | Yes |

`scripts/validate-native.sh` runs this same path locally and in hosted CI.
Provider tests use fake models and injected URL protocols; CI receives no real
model secret.

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

Persistence and workspace tests cover atomic import, digest deduplication,
legacy backup, FTS rebuild and Chinese substring fallback, annotation and
progress round trips, Quick Look capability gating, preferences, index-job
deduplication, durable position restore, Source refresh relocation, security-
scoped bookmark lifecycle, pending frozen-plan adoption, Space generation
isolation, and crash-safe Agent state.

## Native acceptance record

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
manifest records database schema 8, adapter schema 1, Agent runtime schema 5,
ad-hoc signing, Sandbox, and unnotarized state.

The workflow contract makes manual dispatch artifact-only and refuses to
overwrite an existing GitHub Release. No live tag, remote release, or branch
protection was created because this repository currently has no remote. The
Developer Preview remains explicitly ad-hoc signed and not notarized.
