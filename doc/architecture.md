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
one database transaction. If metadata commit fails, the host attempts to move
the trashed container back. Shared bytes remain until the final active Source
reference is removed; the user-selected original is never touched.

The database schema records sources, snapshots, Space membership, adapter
plans, observations/FTS, graphs/plans, annotations, progress/history, Provider
profiles, Agent runs/events/artifacts, and migration facts. Provider secrets
are represented only by Keychain references.

`progress-v1.json` is not decoded into new identities. After the first database
migration succeeds, it is atomically moved to `Legacy/` and recorded in
`migration_manifest` with `boundToNewObjects=false`.
The compatibility reader writes any new vertical-slice state to
`progress-v2.json`, so recreating the database cannot mistake current output
for legacy migration input.

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
  for that Reading Space.
- Network source fetchers and model Providers are separate clients and
  allowlists.
- Staging cleanup can remove only internal rebuildable data, never a selected
  original or committed Source.
- Database initialization and legacy migration run off the main actor. A failed
  database initialization may still restore the distinct current
  `progress-v2.json`, but saving stays disabled unless that load succeeds. The
  app never overwrites unread or unsupported progress with an empty state.
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

## Work owned by later v0.2 slices

- single-agent Provider runtime and structured-output validation;
- full Library/reader UI, annotations, history, and accessibility acceptance;
- sandbox packaging and exact-tag release artifacts.

OCR, sync, accounts, collaboration, third-party plugins, model-controlled file
writes, and notarization remain outside v0.2.
