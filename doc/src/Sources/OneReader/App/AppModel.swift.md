# `Sources/OneReader/App/AppModel.swift`

Owns main-actor application orchestration:

- empty-first-launch Library/Space/Source selection;
- generic local, drag/drop, Open With/Open In, URL, and GitHub import coordination;
- selected deterministic AdapterPlan, content tree, Observation, and native
  presentation;
- per-Source/Snapshot/AdapterPlan atomic indexing jobs with generation-based late-result
  discard;
- Space/Source/Library search, Locator jumps, annotations, progress, and
  history;
- Provider profile editing/testing and Reading Agent task orchestration;
- native notices, large-import confirmation, Source-removal confirmation, and
persisted reader preferences.

Platform-only entry points remain narrow: macOS creates an `NSOpenPanel`, while
iOS/iPadOS publishes a typed `PlatformFileImportPurpose` consumed by the root
`fileImporter`. Both paths rejoin at `importLocalURLs`; reauthorization is
single-selection and imports can be multi-selection.

`OriginalSourceOpenPolicy` keeps the external-source action honest: macOS may
open a local or remote origin, while iOS/iPadOS expose only HTTP(S) origins.
Expired document-provider file URLs never reach `UIApplication`; local reading
continues against the immutable managed Snapshot.

The app creates no demo Source and performs no background example-network call.
Import always commits through `ManagedLibrary`; format-specific presentation
begins only after a committed Snapshot exists. Opening a Source while its
post-import index is already running attaches UI state to the existing job
instead of starting a competing task. A newer Snapshot cancels the old
generation and cannot accept its late result. A directory/repository without a
saved position opens its root README or common index/summary document before an
incidental readable file.

The model never writes Agent output directly. It delegates runs to the runtime,
loads committed graphs/plans/activity, and exposes only host-validated results.
Space transitions cancel search, position, content, and Agent work, then require
both the captured Space ID and workspace generation before any result can be
published. Opening a Space restores its most recent persisted position.

The product Agent pipeline routes every current Snapshot before scouting. A
low-confidence plan waits for confirmation; confirm/dismiss/resume continues at
the next persisted pipeline checkpoint, while standalone evidence answers and
completed route projection stop. The model captures the exact active Run ID for
explicit cancellation, exposes an auditable abandon action for interrupted
work, and lets Provider/Source invalidation remove unrecoverable recovery
prompts. Profile saves, persisted connection tests, and Space Provider overrides
reload the selected Space's Run/Activity cache after database invalidation, so
the Inspector cannot retain a stale resume action. Space
transitions rely on Run-ID-bound stream termination rather than an unscoped
delayed session cancel. Completed graph/route revisions are
loaded as pending while the reader remains on a frozen plan; adoption and valid
progress migration require an explicit user action. Source refresh stages and
probes new bytes under the existing Source identity, resolves annotation and
position anchors, and commits the new Snapshot plus migration states atomically.

Bootstrap also enumerates every active searchable AdapterPlan that lacks a
completed schema-v9 projection and schedules background indexing without
opening its Space.

Activity maps persisted redacted metadata into the Inspector, including Source,
Snapshot, Adapter, Locator digest, and outbound byte range for read tools.
