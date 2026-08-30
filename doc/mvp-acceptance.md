# MVP Acceptance

## Automated gates

| Gate | Command | Required |
| --- | --- | --- |
| Domain and parser tests | `swift test` | Yes |
| Release compilation | `swift build --configuration release` | Yes |
| Documentation index | `python3 scripts/check-doc-index.py` | Yes |
| Native app packaging | `scripts/package-app.sh` | Yes |
| Whitespace | `git diff --check` | Yes |

## GitHub-book acceptance

- The default `time-as-a-friend` repository resolves its live default branch
  and commit SHA.
- The README table of contents becomes ordered reading units.
- Selecting a unit fetches and renders its Markdown lazily.
- Evidence exposes repository path and revision.
- A network failure is visible and does not fabricate content.

## PDF acceptance

- The published demonstration PDF renders through PDFKit.
- A local PDF can be selected through the native open panel.
- A content digest binds page locators to the imported bytes.
- Outline destinations become units; outline-free files receive bounded page
  groups.
- Page controls and evidence navigation update the native `PDFView`.

## Reading acceptance

- Quick, systematic, and review goals create different stable plans.
- Completing a unit updates route progress and survives relaunch.
- Source, unit, and plan progress remain distinguishable.
- The current reading unit can switch between repository, PDF, and comparison
  presentation when both fragments exist.

## Native visual acceptance

Test on the real macOS app:

- wide window around 1440 × 900;
- compact window around 900 × 650;
- system light appearance;
- system dark appearance;
- sidebar and route inspector visible and hidden;
- long Chinese Markdown without horizontal clipping;
- keyboard focus labels and toolbar accessibility;
- PDF zoom and scrolling remain owned by PDFKit.

Record screenshots under `.onereader/qa/`; do not commit local source documents.

## v0.2 adapter acceptance

Generated, non-copyrighted fixtures exercise PDF, EPUB, Markdown, text, code,
HTML, directories, web snapshots, remote documents, public GitHub archives,
and unknown-file Quick Look routing. Contract tests cover every declared
capability and current/relocated locator states. Security fixtures cover ZIP
traversal, symlinks, declared and actual-byte expansion limits, case-colliding
paths, HTML script and event removal, private-address and plain-HTTP rejection,
origin-bound redirects, bounded text loading, and local referenced-resource
escape. Locator tests also prove a stale Markdown line range is recomputed from
its exact quote before reading a new Snapshot.

Network tests use an injected URL protocol and never require external service
availability. They prove full GitHub SHA persistence, same-origin web resource
caching, direct remote Markdown routing, offline reads after commit, FTS search,
and FTS rebuild. End-user Library/workspace interaction and VoiceOver evidence
are owned by the native workspace slice.

## Verified baseline

The 2026-07-23 MVP baseline passed all automated gates and real-app acceptance:

- 12 Swift tests passed, covering GitHub parsing, PDF inspection, locators,
  evidence-backed mapping, plan projection, and progress persistence.
- The packaged app resolved `time-as-a-friend` at commit `ba8305d`, rendered
  live Markdown, and opened the 306-page third-edition PDF through PDFKit.
- Repo/PDF comparison, goal switching, completion, next-unit navigation, and
  relaunch recovery were exercised in the native UI.
- 1440 × 900 light/dark and 900 × 650 compact layouts were inspected.
  Screenshots are retained locally under `.onereader/qa/`.

## Known MVP limitations

- The default mapper is deterministic rather than model-backed.
- Repository import supports public GitHub repositories only.
- Markdown rendering intentionally covers reading-oriented blocks rather than
  every GitHub-flavored HTML extension.
- Demo repository/PDF alignment uses explicit public-edition hints and is
  labeled as such.
- The packaged app is unsigned and not notarized.
