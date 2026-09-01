# Architecture

## Product boundary

OneReader exposes heterogeneous material as an explorable, locatable content
space. The reader operates on virtual reading units without forcing PDFs,
webpages, EPUBs, directories, or repositories into one physical format.

## Runtime layers

```text
User-selected Source
    ↓
Staging copy + digest/tree revision
    ↓
Immutable managed SourceSnapshot
    ↓
Capability probe + AdapterPlan
    ↓
Observation + SourceFragment
    ↓
ReadingGraph + frozen ReadingPlan
    ↓
Native reader + local annotations/progress/history
```

Deterministic adapters are the availability boundary. An optional Reading Agent
may propose adapter combinations and graph patches, but it does not own source
fetching, storage, database writes, or basic readability.

## Reading Agent runtime

Each Reading Space has one long-lived `ReadingAgentSession` actor. A session
starts bounded turn loops for adapter routing, scouting, graph materialization,
route projection, or evidence answers. Runs stream ordered factual events while
their complete transcript, projected model context, artifacts, structured
output, and lifecycle state remain durable in the Library database.

SwiftAgent owns typed generation and tool-loop mechanics. OneReader owns the
generation/snapshot-manifest token, budgets, four-read concurrency gate, hard
context projection, Provider endpoint transport, recovery, validation, and
every database transaction. The
only model-visible tools list/inspect/read/search/resolve existing managed
content; there is no shell, source fetch, write, dispatch, MCP, Skill, or
sub-agent surface. See [Reading Agent runtime](reading-agent-runtime.md).

## Native composition

- SwiftUI owns window structure, navigation, inspector, selection, loading
  state, commands, focus, and accessibility.
- AppKit bridges native open panels, Finder Open With, Quick Look, and window
  behavior.
- PDFKit owns PDF layout, zoom, selection, and page navigation.
- WebKit displays only sanitized, app-served EPUB/HTML content.
- Foundation `URLSession` owns remote source fetches outside the Agent runtime.
- GRDB `DatabasePool` owns migrations, WAL concurrency, FTS5 indexes, and
  serialized transactions.

The window uses one outer `NavigationSplitView` for Library navigation. Inside
an open Space, a SwiftUI reading stack owns Outline/Sources/Route/Search,
content, and the Inspector. The Inspector is an in-layout trailing column at
wide sizes and a dismissible overlay drawer at compact sizes. It deliberately
does not use a second AppKit split view or window-level Inspector, avoiding
conflicting minimum-width constraints around PDFKit and selectable text.

## Managed Library

`~/Library/Application Support/OneReader/` contains:

- `Library.sqlite` for durable metadata and indexes;
- `Sources/` and `Snapshots/` for immutable managed content;
- `Derived/` for rebuildable extraction, sanitization, and thumbnails;
- `Artifacts/` for large Agent/tool results;
- `Legacy/` for migration backups;
- `.Staging/` for incomplete internal imports.

Local import copies into staging, calculates and rechecks a SHA-256 or stable
directory-tree digest, then moves the complete staging directory to a
content-addressed final path. Source, snapshot, and Space membership rows commit
in one database transaction. Reimporting identical content creates no second
byte copy.

For a single Markdown or HTML file, the snapshot also copies referenced regular
files below the selected parent directory. The immutable snapshot digest covers
the primary file and referenced resources, while `revision` retains the primary
file digest used by its format adapter. References that escape the authorized
directory or traverse a symlink are rejected.

Import capacity is checked through an injectable policy: production requires
confirmation above 4 GiB and preserves at least 2 GiB free after commit, while
tests use byte-scale limits. A deduplicated import is charged zero additional
managed bytes. Directory digests include package descendants and fail if any
entry cannot be enumerated, so an unreadable subtree cannot alias a complete
tree.

Removing a Source moves only exclusively owned content-addressed containers to
the macOS Trash, then marks the Source removed and detaches Space membership in
one database transaction. That same commit removes Source-bound annotations and
history, clears the Source position, invalidates graphs/frozen plans and their
unit/plan progress, and cancels active Agent runs while advancing each affected
session generation. If metadata commit fails, the host attempts to move the
trashed container back. Shared bytes remain until the final active Source
reference is removed; the user-selected original is never touched.

The database schema records sources, snapshots, Space membership, adapter
plans, raw observations, plan-bound search projections, graphs/plans,
annotations, progress/history, Provider
profiles, Agent runs/events/artifacts, and migration facts. Provider secrets
are represented only by Keychain references.

Schema v8 stores security-scoped bookmark data separately from Source identity
for local file/directory refresh across Sandbox launches. The bookmark is never
exposed to an adapter or Agent, is renewed when stale, and is deleted when the
Source is removed. If import cannot create the bookmark, the managed Snapshot
still becomes readable and Activity exposes the refresh-authorization warning;
stale renewal failure requires explicit native reauthorization.

Schema v9 separates evidence Observations from the user-visible search
projection. One active AdapterPlan is selected per Snapshot. Index staging and
publication are keyed by both Snapshot and plan ID, and final publication uses
an active-plan compare-and-swap. A late index from a superseded plan cannot
replace current search results, while ordinary Agent/tool reads remain durable
evidence without becoming global FTS content. The v8 migration intentionally
discards the unbound legacy FTS projection; application bootstrap then finds
all active searchable plans without completed v9 projections and rebuilds them
in the background, including Spaces the user has not opened.

`progress-v1.json` is not decoded into new identities. After the first database
migration succeeds, it is atomically moved to `Legacy/` and recorded in
`migration_manifest` with `boundToNewObjects=false`. All current annotations,
progress, history, graphs, and plans live only in `Library.sqlite`; there is no
parallel live JSON progress store.

## Revision and evidence rules

- GitHub snapshots bind to an exact commit SHA when the API is available.
- Managed files bind to a content digest; directories bind to a sorted tree
  digest.
- Locators include source, snapshot, adapter, schema, structural/quote anchors,
  and fingerprints.
- A refreshed source creates a new snapshot. Old locators remain historical and
  can become relocated or orphaned; they are never rewritten as current.
- Every generated ReadingUnit retains at least one real SourceFragment.

## Trust boundaries

- Source content is untrusted data and never becomes a system instruction.
- Deterministic reading requires no token, account, or API key.
- Local bytes do not leave the Mac unless the user authorizes a remote Provider
  destination for that Reading Space. Consent binds the canonical endpoint, so
  changing a profile destination invalidates the old acknowledgment.
- Network source fetchers and model Providers are separate clients and
  allowlists. A temporary model-construction hook gives each Provider SDK a
  dedicated, leased endpoint guard; the process-wide default configuration is
  restored immediately. The guard rejects out-of-scope requests after profile
  switches or lease expiry and refuses all redirects before response or
  streaming data reaches the SDK.
- Staging cleanup can remove only internal rebuildable data, never a selected
  original or committed Source.
- Database initialization and legacy migration run off the main actor. A failed
  database initialization surfaces a blocking Library notice and installs no
  persistence authority; the app never overwrites unread state with an empty
  replacement.
- There is no bundled fallback book. Network failure must remain visible and
  must not fabricate a revision or content.

## Deterministic adapters and remote ingestion

The standard registry provides PDF, EPUB, Markdown, text, code, HTML, web
snapshot, directory, and Quick Look adapters. Each independently declares and
implements Probe, Revision, List, Read, Search, Render, and Resolve capabilities;
Quick Look intentionally declares only probe, render, and source-level resolve.

Remote ingestion routes public GitHub URLs to an exact-SHA archive fetch and
other public-address HTTPS URLs by response media type. HTML becomes a managed web snapshot
with bounded same-origin resources; direct PDF, EPUB, Markdown, text, and
unknown documents become managed immutable files. Redirect, archive, HTML, and
resource boundaries are enforced before an adapter sees the snapshot. See
[Source adapters](source-adapters.md).

## Native reader workspace

The first launch is an empty Library. Drag/drop, Open, Open With, and URL paste
all enter one import coordinator; format selection is never a product-level
choice. A Source can enter a new Space or join the active Space. Deterministic
indexing is deduplicated per Source/Snapshot/AdapterPlan generation, so opening a newly
imported Source cannot race a second index job and leave Processing stuck.

Native PDFKit, selectable Markdown/text/code, controlled WebKit, and Quick Look
presentations share the same reading surface. Search results, annotations,
history, source positions, ReadingUnits, and frozen plan steps retain their
snapshot-bound Locators. Reader preferences persist independently in
`UserDefaults`; all Library facts remain in GRDB. See
[Reader workspace](reader-workspace.md).

The remaining v0.2 delivery slice owns exact-tag DMG/ZIP release artifacts and
their manifest. OCR, sync, accounts, collaboration, third-party plugins,
model-controlled file writes, and notarization remain outside v0.2.
