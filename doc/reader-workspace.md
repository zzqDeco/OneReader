# Reader Workspace

## Product shape

OneReader opens as a Library, not a format picker or chat screen. A Reading
Space can contain one or more local files, directories, web snapshots, or
public GitHub snapshots. Adding material always starts with a generic Source;
the deterministic registry chooses the immediately readable presentation and
the optional Reading Agent may later propose additional structure.

The primary workspace contains:

- All Spaces, Recent, Processing, Favorites, and Space navigation;
- Outline, Sources, Route, and Search navigation for the open Space;
- one central native reading surface;
- a trailing Inspector for annotations, evidence, factual Agent Activity, and
  evidence-grounded questions.

The Agent never replaces the reading surface and basic reading never waits for
a Provider.

## Import and Processing

Drag/drop, Command-O, Finder Open With, SwiftUI `fileImporter`, iOS/iPadOS Open
In, and URL paste share `AppModel` import coordination. The import first appears
as Processing, then commits a managed
Snapshot and installs a deterministic AdapterPlan. Index work is keyed by
Source ID, Snapshot ID, AdapterPlan ID, and a generation token. A second request
for the same plan attaches to the existing job; a new Snapshot or plan cancels
the obsolete generation and discards its late result.

When a directory or repository opens without a saved Locator, the reader
prefers a root README, then common index/summary/TOC names, before falling back
to the first readable child. Incidental license or asset files therefore do not
replace the book overview as the initial reading surface.

A failed item stays visible with its error and can be dismissed. Source removal
requires an explicit confirmation. An exclusive managed copy moves to macOS
Trash or a persistent transaction-safe iOS removal journal; the original
selected item is never modified. Failed iOS restoration is retried during the
next Library initialization rather than being abandoned in a temporary
directory. The
database transaction also detaches the Source, removes its annotations and
history, invalidates graphs/frozen routes, clears their unit/plan progress, and
cancels active Agent runs for every affected Space. If that transaction fails,
the host attempts to restore the managed copy from Trash.

Refreshing an existing Source stages a new immutable managed Snapshot under the
same Source identity, probes and indexes it independently, then commits the
revision and anchor migrations together. Exact structural/quote matches become
`relocated`; missing evidence becomes `orphaned`. The previous Snapshot and old
Locator are retained and are never rewritten to look current.

## Presentation surfaces

| Content | Surface | Native behavior |
| --- | --- | --- |
| PDF | PDFKit | continuous pages, selection, page Locator, zoom |
| Markdown | `swift-markdown` AST plus `NSTextView`/`UITextView` | selectable rich headings, lists, quotes, code, tables, and safe links |
| Text | `NSTextView`/`UITextView` | selectable, themed, bounded line width |
| Code | monospaced `NSTextView`/`UITextView` | selectable with horizontal scrolling |
| HTML/EPUB/web snapshot | controlled WKWebView | app-served sanitized bytes and explicit external-link handoff |
| Unknown file | Quick Look | source-level bookmark/note only, with the limitation shown |

Native Markdown drops raw HTML, never loads Markdown image URLs, and exposes a
readable alt-text placeholder. Leaf text carries deterministic source UTF-16
attributes through heading, emphasis, list, and code styling. Mapping begins
from each `swift-markdown` AST leaf `SourceRange`; inline-code delimiters and
fenced-code delimiter/language lines are then removed before alignment. UTF-8
byte columns are converted to source UTF-16 offsets, and escape/entity
expansions retain the whole source token as their anchor. Link destinations,
code syntax, and omitted raw HTML are therefore never candidates for visible
text. A leaf installs mapping attributes only when every visible UTF-16 unit is
covered. Code-span newline normalization, indented fences, and indented code
blocks therefore drop the whole leaf map instead of exposing a partial or
syntax-anchored range. An explicit unavailable-map sentinel propagates that
failure through selections crossing either edge of the leaf, so an adjacent
mapped space cannot become a partial Locator. Selections and positions map
rendered ranges back to exact source ranges (and fail closed when no map exists),
so repeated text never falls back to a first/unique-match guess.

Controlled WebKit resources are confined to the Snapshot root, reject symlinks
and unsupported MIME types, cap each resource at 32 MiB, and stream in 256 KiB
chunks with cancellation. Scheme callbacks and stop are serialized so no
response/data/finish/failure callback occurs after stop returns. Source
JavaScript, automatic navigation, and
cross-Snapshot loads remain disabled. The system reader theme follows the live
platform color scheme.
Nested HTML uses the same Snapshot resource root for sanitizer rewriting and
scheme resolution, so `chapters/page.html` can load a rewritten
`chapters/img/a.png` without duplicating the chapter path.

## Search, annotations, and progress

Search can target the current Source, current Space, or complete Library.
Results include title, source, Snapshot-bound Locator, and jump context. The
FTS fast path has a bounded exact-substring fallback for unsegmented scripts.
Indexed hits derive a query-specific quote/range Locator while preserving PDF
page identity. Only the active AdapterPlan's completed projection is visible;
ordinary evidence reads are never indexed implicitly. Publication compares the
Snapshot/plan pair transactionally, and interrupted staging is discarded on
restart. When schema v9 replaces the legacy v8 FTS table, bootstrap enumerates
every active searchable AdapterPlan without requiring the user to open its
Space and schedules a deterministic projection rebuild.

Bookmarks bind the current presentation Locator. Highlights require a real
selection and a presentation that supports structured anchors. Notes can bind
the selection or current position. Quick Look never advertises structured
highlight or AI evidence. Annotation rows expose current, relocated, or
orphaned anchor state.

Progress stores source position, per-unit completion, current frozen-plan step,
and reading history independently. Opening a search result, annotation, graph
unit, or evidence citation resolves its Locator before presentation. Text and
Markdown surfaces select and scroll to the quote (using prefix/suffix context
to disambiguate repeats), WebKit scrolls to a validated DOM/quote anchor, and
PDFKit navigates to the recorded page and prefers its clipped selection rectangle
before quote-only fallback. A rect-derived selection is shown only when it
matches the stored exact quote, but the rect still determines the reading
position when repeated page text would make the first quote match ambiguous.

Each presentation emits a throttled current-position Locator. Reopening a Space
restores its most recent Source position, and the Route view exposes unit
completion plus reading history. Agent-generated graph/route revisions remain
pending while the reader is on a frozen plan; adopting a pending route is an
explicit action that migrates only still-valid progress.

Agent adapter routing runs per explicit current Source/Snapshot target before
scouting and graph materialization. Low-confidence proposals stay in Activity
for confirmation. Confirming, dismissing, or resuming continues from the next
persisted pipeline checkpoint; standalone questions and completed route
projections stop instead of starting the structure pipeline. Another wait stops
the pipeline again. Interrupted work can be explicitly abandoned, while stale
Provider or Source bindings terminate it automatically. Leaving a Space cancels
only the Run that owns the terminated event
stream, so a delayed A-to-B transition cannot cancel a newer Run after returning
to A.
Activity rows preserve redacted Source, Snapshot, Adapter, Locator digest, and
outbound byte-range metadata so the disclosure describes what was actually
sent without storing body text, paths, or notes.

## Responsive and accessible behavior

macOS uses a 338-point trailing Inspector at wide sizes and a dismissible drawer
below a 920-point detail width, preserving the reader at the 900 x 650 minimum.
Regular-width iPad keeps Library, reading navigation, content, and an optional
Inspector in the adaptive split workspace. Compact-width iPhone lets the system
collapse Library navigation, keeps the reader full width, and presents
Outline/Sources/Route/Search and Inspector in separate medium/large sheets. The
iPhone footer becomes a horizontally scrollable icon control row rather than
compressing actions below their usable size.

macOS commands expose import, Space import, search, previous/next content,
bookmark, highlight, and the 900 x 650 / 1440 x 900 window presets. iPhone and
iPad expose import, reading navigation, search, Inspector, and Settings in the
toolbar and preserve hardware-keyboard shortcuts where the platform supports
them. Controls and search results have explicit accessibility labels, text is
selectable, and animation honors Reduce Motion. Reader theme, font size, line
width, line spacing, and PDF scale persist across launches.

The Open Original control is capability honest. macOS can hand its saved local
origin to Finder; iOS/iPadOS show the control only for explicit HTTP(S) origins.
An expired local document-provider URL is never displayed as usable. Managed
Snapshots remain readable and refresh requests exact native reauthorization.
