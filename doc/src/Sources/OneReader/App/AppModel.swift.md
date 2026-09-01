# `Sources/OneReader/App/AppModel.swift`

Owns main-actor application orchestration:

- empty-first-launch Library/Space/Source selection;
- generic local, drag/drop, Open With, URL, and GitHub import coordination;
- selected deterministic AdapterPlan, content tree, Observation, and native
  presentation;
- per-Source/Snapshot/AdapterPlan atomic indexing jobs with generation-based late-result
  discard;
- Space/Source/Library search, Locator jumps, annotations, progress, and
  history;
- Provider profile editing/testing and Reading Agent task orchestration;
- native notices, large-import confirmation, Source-removal confirmation, and
  persisted reader preferences.

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
the next Source checkpoint, while another waiting state pauses again. Space
transitions rely on Run-ID-bound stream termination rather than an unscoped
delayed session cancel. Completed graph/route revisions are
loaded as pending while the reader remains on a frozen plan; adoption and valid
progress migration require an explicit user action. Source refresh stages and
probes new bytes under the existing Source identity, resolves annotation and
position anchors, and commits the new Snapshot plus migration states atomically.

Activity maps persisted redacted metadata into the Inspector, including Source,
Snapshot, Adapter, Locator digest, and outbound byte range for read tools.
