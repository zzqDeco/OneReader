# Reader Workspace

## Product shape

OneReader opens as a Library, not a format picker or chat screen. A Reading
Space can contain one or more local files, directories, web snapshots, or
public GitHub snapshots. Adding material always starts with a generic Source;
the deterministic registry chooses the immediately readable presentation and
the optional Reading Agent may later propose additional structure.

The primary workspace contains:

- All Spaces, Recent, Processing, Favorites, and Space navigation while the
  Library is active;
- Outline, Sources, Route, and Search navigation in the same leading column
  after a Space opens;
- one central native reading surface;
- optional trailing Reading Assistance for notes, citations, factual run
  activity, and evidence-grounded questions.

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

Native Markdown drops raw HTML and never fetches remote Markdown image URLs.
Relative images are resolved only through the same read-only Snapshot-root
loader used by controlled WebKit, including path/symlink containment, MIME, and
32 MiB limits. Image metadata is inspected before decode, source dimensions are
bounded to 16,384 pixels and 64 Mi pixels, and accepted images are downsampled
to a 4,096-pixel maximum decoded edge; unavailable or remote images keep a
readable alt-text placeholder. Rendered image attachments are deliberately
unlocatable text, so selection cannot fabricate an anchor. Tables use readable
bordered rows rather than tab-separated fallback text. Leaf text carries deterministic source UTF-16
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
and reading history independently. Each Source position carries its immutable
Snapshot Locator, a presentation granularity, optional normalized fraction, and
a short resume label. Opening a search result, annotation, graph
unit, or evidence citation resolves its Locator before presentation. Text and
Markdown surfaces select and scroll to the quote (using prefix/suffix context
to disambiguate repeats), WebKit scrolls to a validated DOM/quote anchor, and
PDFKit navigates to the recorded page and prefers its clipped selection rectangle
before quote-only fallback. A rect-derived selection is shown only when it
matches the stored exact quote, but the rect still determines the reading
position when repeated page text would make the first quote match ambiguous.
WebKit also stores a normalized scroll fraction as a fallback when structural
and quote relocation cannot find the old anchor.

All presentation surfaces emit one normalized position stream:

| Material | Recorded and restored position |
| --- | --- |
| PDF | exact Snapshot, page index, normalized page fraction; selection rectangles remain annotation anchors |
| Markdown, text, code | source UTF-16/range, line, quote/fingerprint, normalized text fraction |
| HTML and web snapshot | DOM path, quote/fingerprint, normalized scroll fraction |
| EPUB | spine `href` plus the controlled-Web DOM/quote/fraction position |
| directory, local Git, GitHub | child relative path plus that child's text, PDF, or DOM position |
| Quick Look fallback | Source/Snapshot document-level last-open position only |

Native text bridges keep one coalescer for a live-scroll burst and wait 150 ms
after its latest bounds change, so text layout, quote extraction,
observable-model mutation, and storage scheduling do not run on every display
frame. AppKit publishes immediately at live-scroll end; UIKit does so when drag
or deceleration ends. The normalized position stream then uses a 350 ms
persistence debounce. Before any Source/Space switch or inactive-scene flush,
the host synchronously asks the active native bridge for its current sample and
persists that fresh update before changing generation. Reopening a Space
restores its most recently updated Source.
The reader footer shows the saved label, and Library cards show the latest
resume target plus aggregate Source reading fraction even when no Provider or
Reading Graph exists. Graph-unit completion remains a separate route fact and
is only the card's fallback when no Source fraction has been observed.

The Route view exposes unit completion plus reading history. Agent-generated graph/route revisions remain
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

## Native editorial hierarchy

The Library uses a quiet grouped background, one bounded continuation card,
and a scannable shelf of stable solid-color covers. It does not use decorative
gradients or dashboard-style metric cards. System sans-serif type belongs to
application chrome; Markdown/text prose uses the platform serif design; code
remains monospaced. Prose measure is capped at 720 points across native and
controlled-Web surfaces.

Opening a Space replaces Library navigation with its reading navigation rather
than nesting another column. Reading Assistance is collapsed by default and is
opened deliberately. User-facing chrome says 阅读空间、阅读辅助、引用 and 版本;
adapter names, digests, and identifiers live only in explicit run or citation
detail disclosures.

Directory outlines filter actual image and font media rather than directory
names. A readable `assets/README.md` therefore stays visible, while cover bytes
remain out of the reading sequence. Previous/next uses that same readable node
set, so sequential navigation cannot enter an item hidden from the outline.

## Responsive and accessible behavior

macOS uses a 338-point trailing Reading Assistance panel at wide sizes and a
dismissible drawer below a 760-point detail width, preserving the reader at the
900 x 650 minimum. Regular-width iPad uses the same adaptive split workspace.
Compact-width iPhone keeps the reader full width and presents
Outline/Sources/Route/Search and Reading Assistance in separate medium/large
sheets. It has one system inline navigation title and one stable bottom bar
with four minimum-44-point actions: directory, previous item, next item, and
notes. There is no second custom title bar or horizontally scrolling toolbar.

macOS commands expose import, Space import, search, previous/next content,
bookmark, highlight, and the 900 x 650 / 1440 x 900 window presets. iPhone and
iPad expose import, reading navigation, search, Reading Assistance, and Settings in the
toolbar and preserve hardware-keyboard shortcuts where the platform supports
them. A toolbar or keyboard search request also reveals a hidden navigation
column (or the compact navigation sheet) before selecting Search. Controls and
search results have explicit accessibility labels, text is
selectable, and animation honors Reduce Motion. Reader theme, font size, line
width, line spacing, and PDF scale persist across launches.

The Open Original control is capability honest. macOS can hand its saved local
origin to Finder; iOS/iPadOS show the control only for explicit HTTP(S) origins.
An expired local document-provider URL is never displayed as usable. Managed
Snapshots remain readable and refresh requests exact native reauthorization.
