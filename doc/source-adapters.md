# Source Adapters

## Availability boundary

Every committed `SourceSnapshot` is offered to the deterministic adapter
registry before any model is involved. The registry probes registered adapters,
selects the highest-confidence primary adapter, records probe evidence, and
routes each declared capability through an `AdapterPlan`. Unsupported
capabilities are absent rather than simulated.

The v1 registry contains:

| Adapter | Source shape | Presentation | Capabilities |
| --- | --- | --- | --- |
| PDF | PDF signature or extension | PDFKit | probe, revision, list, read, search, render, resolve |
| EPUB | validated EPUB ZIP/package | sanitized WebKit | all adapter capabilities |
| Markdown | UTF-8 Markdown | native selectable text | all adapter capabilities |
| Text | UTF-8 text | native selectable text | all adapter capabilities |
| Code | known source extension | native monospaced text | all adapter capabilities |
| HTML | parseable local HTML | sanitized WebKit | all adapter capabilities |
| Web snapshot | managed manifest plus `index.html` | sanitized WebKit | all adapter capabilities |
| Directory | managed directory or repository tree | native tree plus child adapters | all adapter capabilities |
| Quick Look | otherwise unknown regular file | Quick Look | probe, render, resolve only |

Directory and GitHub repository sources are compositions. Their tree is owned
by the directory adapter while readable child files retain their own Markdown,
HTML, PDF, EPUB, code, text, or Quick Look locator and presentation.
Index expansion reads every PDF page and every EPUB spine item rather than only
the container file. Directory-child EPUB extraction is namespaced below the
Snapshot by a digest of its relative path, so multiple books cannot share or
overwrite one derived root.

## Import and snapshots

The ingestion host, not an Agent, decides how to materialize a Source:

- local files and directories use the Managed Library staging transaction;
- a single local Markdown/HTML file also copies referenced regular-file
  resources that remain below its selected parent directory;
- direct remote document URLs become immutable managed files and are probed by
  content/media type;
- web pages become a directory snapshot containing `index.html`, a versioned
  manifest, and bounded same-origin image resources;
- public GitHub URLs resolve repository metadata and the default branch through
  the API, then download and safely extract the exact commit archive;
- GitHub SourceSnapshot revisions are full 40-character commit SHAs.

Remote document imports require HTTPS. Before the first request, the host must
resolve exclusively to public addresses; loopback, link-local, private,
documentation, multicast, IPv4-embedding transition, and reserved ranges are
rejected. Redirects stay on the original HTTPS allowlisted host. Web resources
stay on the page origin and are
bounded per item and in aggregate, and failures remove the resource reference
without preventing the text snapshot from being readable. Download delegates
cancel the transfer as soon as actual or announced bytes exceed the limit,
before temporary bodies are mapped into memory. Network fetches are cancellable
and have no model credentials.

If a format-specific probe fails after import, the registry records a redacted
`probe-failed` evidence item and continues probing. A regular file can therefore
degrade to the explicitly limited Quick Look plan instead of making the entire
snapshot unreadable.

## Locator and revision behavior

All locators carry `sourceID`, `snapshotID`, `adapterID`, locator schema, opaque
payload, and optional structural path, exact quote, and fingerprint. Adapters
accept positional locators only when the Snapshot ID is current. Cross-revision
resolution returns one of:

- `current` when the original snapshot is still selected;
- `relocated` when structural path or exact quote validates against a new
  snapshot;
- `orphaned` when validation fails.

No adapter mutates or silently re-labels the historical locator. Markdown,
code, and text locators with a line range require the exact quote during
relocation and receive recomputed start/end lines before they can be read
against the new Snapshot.
Repeated text is disambiguated by quote prefix/suffix, then proximity to the
original UTF-16 offset. Equally ranked matches are orphaned, never silently
resolved to the first occurrence. Indexed text ranges also receive fresh
absolute UTF-16 coordinates; viewport locators retain their reading semantics.

## Archive and web safety

ZIP extraction rejects absolute paths, traversal, backslashes, NUL paths,
Unicode/case-colliding duplicates, symlinks, CRC failures, and expansion beyond
the configured ratio/byte ceiling. The extractor counts the chunks it actually
writes, so false ZIP size metadata cannot bypass the ceiling. EPUB production
extraction is limited to ten times compressed size and at most 4 GiB.

HTML and EPUB documents are parsed with SwiftSoup and stripped of scripts,
forms, frames, embedded objects, active media, and event attributes. A strict
Content Security Policy disables script, network connections, frames, and
uncached resources. WebKit receives local bytes only through the
`onereader-content` read-only scheme. Automatic navigation is rejected;
HTTP(S) links leave the app only after a real link activation.

EPUB and local/web HTML resource references are rewritten to root-relative
`onereader-content` URLs only after the referenced regular file is verified
inside that snapshot root. This preserves common EPUB `text/` to `images/`
sibling layouts without widening the scheme boundary. Sanitization and
presentation share that exact root even when an HTML file is nested inside a
managed directory, preventing duplicated relative path components.

Quick Look is deliberately weaker: it exposes no structured read, search,
highlight, or AI-evidence capability and only supports source-level bookmark
and note behavior.

Structured Markdown, code, text, and individual EPUB spine documents are read
through a 64 MiB byte ceiling. Larger regular files remain available through
the explicit Quick Look fallback instead of being materialized as an unbounded
Swift `String`.

## Search and observations

Reads produce snapshot-bound `Observation` values with digest, truncation,
media type, and optional managed-content reference. Raw Observations are
durable evidence and do not automatically become searchable. The coordinator
builds a separate FTS5 projection under an explicit AdapterPlan: it stages the
complete plan output, verifies that the same plan is still active for the
Snapshot, then publishes atomically. FTS results retain source, snapshot,
adapter, locator, title, and jump context.

Markdown headings are navigation, not index content. The optional host-only
`IndexingAdapter` hook emits the entire permitted Markdown/text/code document
in 64K Swift-Character (extended grapheme cluster) chunks with 512-character
overlap. Files are loaded once per indexing pass under the 64 MiB input ceiling.
Every chunk carries absolute UTF-16 and line offsets; CRLF counts as one line
break. Search anchors rebase those offsets, preserve complete Unicode graphemes,
and deduplicate overlapping hits before the final 20-result limit. Results are
fragment-level matches, not an enumeration of every occurrence in one fragment.
Directory child text uses the same hook; PDF pages and EPUB spine traversal keep
their existing adapters. The hook is not an Agent capability or tool.

Index work is serialized across coordinators by one process-wide cancellable
FIFO gate, including bootstrap. Each Source run permits at most 10,000 directory
entries/expanded content nodes, 10,000 fragments, and 128 MiB of UTF-8 content plus
metadata. A sentinel list entry detects overflow. Truncated reads or exhausted
budgets fail instead of publishing incomplete results. Before writes and commit,
the host requires the normal 2 GiB free-space floor plus at least 32 MiB or eight
times the projection size for staging/publication/FTS/WAL. Failed staging is
deleted transactionally; SQLite pages remain reusable without a blocking vacuum.
Opening the Source or restarting the app retries an incomplete index, without
an automatic failure loop. Basic reading stays available throughout.

Schema v10 invalidates the old heading-only derived projections and completion
records. Bootstrap rebuilds active plans even for unopened Spaces. Source bytes,
Snapshot identities, evidence Observations, notes, progress, and history are not
rewritten. Library search reads only completed projections; Space/Source search
is index-first with a direct adapter fallback only when there are zero index hits.

FTS5 `unicode61` remains the fast path. When its tokenization produces no hit,
the database performs a bounded exact-substring query over the active completed
search projection. This keeps Chinese and other unsegmented scripts searchable without
falling through to an expensive scan of every managed file in a directory.

Removed sources are filtered from FTS queries and rejected by the coordinator
immediately. Rebuildable EPUB extraction directories are keyed by Snapshot ID
and reclaimed when their Source is removed; abandoned `.staging-*` extraction
directories and Snapshot directories without an active Source are swept at
startup. Long indexing, directory search, download, and archive loops check
cooperative cancellation.
