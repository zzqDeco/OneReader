# Reading Agent Runtime

## Product boundary

The Reading Agent is an optional assistant behind the reader, not the product
home screen. Deterministic adapters make every supported Source readable first.
The Agent may explore managed evidence and propose structure, but Source bytes,
network ingestion, database writes, and presentation authority remain with the
host.

One session actor exists per Reading Space. It can run five task shapes:

| Task | Accepted result |
| --- | --- |
| `routeAdapters` | registered, snapshot-bound `AdapterPlan` |
| `scoutSpace` | bounded factual summary |
| `materializeGraph` | evidence-grounded `GraphPatch` |
| `projectRoute` | frozen `ReadingPlanDraft` for one graph version |
| `answerWithEvidence` | answer with current, observed quotations |

## Turn lifecycle and recovery

A run moves through queued, running, waiting-for-user, completed, failed,
cancelled, or interrupted. `AsyncThrowingStream<AgentEvent>` drives Activity,
while the database records the same ordered events. Events expose phases,
tools, durations/budgets, validation outcomes, and error categories; they never
expose hidden reasoning.

For read-only tool calls, events retain only redacted audit identity: Source,
Snapshot, Adapter, a SHA-256 Locator digest, requested bounds, and the exact
outbound tool-result byte range. Body text, file paths, API material, and user
notes are never copied into event metadata. The Inspector renders this metadata
so the remote disclosure can be audited against actual fragments.

Every new run increments the Space generation and binds the exact
`sourceID -> snapshotID` manifest plus immutable Provider destination/revision
identities owned by the host at that instant. Tools, models, validation,
transcript projection, disclosure, and the final database transaction recheck
those bindings, so cancellation-resistant late responses, a Provider edit, or a
Source refresh cannot become current results. A shared barrier acquires one
unique lease for every Space attached to the Source before the runtime awaits
any individual Session. Lease counts keep Spaces blocked across overlapping
refreshes; completing or aborting one refresh cannot release another. Run
insertion executes inside the same barrier actor, closing the last check/insert
race. The Run row and its sequence-zero queued event are inserted in the same
database transaction, so Activity can never observe an orphaned queued Run or
compete with another terminal writer for sequence zero. The returned durable
generation is synchronized back into each session
before that lease is removed. Cancelling a queued concurrency waiter removes it
without leaking or duplicating a permit.

`routeAdapters` additionally requires one explicit target Source ID and
Snapshot ID from that manifest. The target survives request reconstruction,
resume persistence, prompt projection, and final validation; an adapter result
for another current Source in the same Space is still rejected.

Application startup atomically marks incomplete runs interrupted and appends a
matching Activity event; it never replays Provider or fetch calls. Only an
explicit resume creates a new run linked to the interrupted run. A database
uniqueness constraint and parent-state compare-and-swap permit only one child
for that parent. A persisted low-confidence candidate may instead be confirmed
or dismissed locally after restart without making another Provider request.

Remote disclosure waits are resumable after acknowledgment. A routing proposal
below 0.85 confidence is different: it remains a stored candidate while the
deterministic plan stays active. The user must explicitly confirm or dismiss
it. Confirmation revalidates the current Snapshot and persists a user override;
starting a newer run transactionally supersedes every older queued, running,
or waiting run in that Space. Source refresh goes through one production
coordinator that installs the barrier, stops in-memory Provider work, atomically
advances the Snapshot pointer, cancels persisted active/waiting runs, increments
the durable session generation, synchronizes the actor clock, and only then
reopens the Space to new runs.

Session cancellation persists the old Run and captures its task/recorder before
the actor first suspends; it never rereads mutable task state after an `await`.
Every asynchronous start attempt carries a host token checked after each
suspension and again before task installation. Caller task cancellation is
checked at those same boundaries; if it arrives after persistence, the queued
Run is terminalized before cancellation escapes and no Provider task is
installed. A newer start or session cancellation
invalidates that token, and any already-persisted stale Run is cancelled without
touching the replacement task. This prevents actor reentrancy from letting an
older cancel/start continuation cancel or install over a newer generation.
Event-stream termination uses a Run-ID comparison and generation-conditional
clock invalidation and does not clear a replacement start token.
Ordinary Activity appends transactionally require an active queued/running Run
and the exact next sequence. Recorder shutdown replays any not-yet-published
persisted events before closing the stream. A cancellation or supersession that
wins the database transaction is therefore the final event in both durable
history and the UI stream, even when the old task ignores cancellation long
enough to attempt another tool event. If such obsolete work later returns a
different local error, the turn loop rereads the durable Run state; durable
cancelled/interrupted state closes Activity normally instead of surfacing that
losing error after the cancellation event.

## Provider boundary

Profiles support Apple Foundation Models on device, OpenAI Responses-compatible
HTTPS endpoints, Anthropic Messages-compatible HTTPS endpoints, and loopback
Ollama. The user supplies the model ID. Remote secrets live only in macOS
Keychain; SQLite, events, and logs store a Keychain reference and redacted
metadata.

Connection testing proves four capabilities independently: connection,
structured generation, one exact-nonce tool call, and streaming. Each phase has
a real deadline within one whole-probe timeout that returns even if an SDK
operation ignores cancellation. A host wrapper permits at most two structured
model responses, exactly one tool invocation, and one streaming response;
repeated or concurrent tool calls fail the probe. All HTTP responses in that
probe share one cumulative raw-response budget rather than resetting it per
request. Anthropic 0.5.5 cumulative text prefixes are compared as exact UTF-8
bytes and normalized into deltas before SwiftAgent aggregation; canonically
equivalent but byte-distinct prefixes fail closed. The streaming probe succeeds
only when its final content is exactly `ok`. An unsaved Provider draft can be
tested with its explicit in-memory secret before a Keychain reference exists.
Draft probes receive no persistence authority, and replacing the secret always
makes the result non-persistable. Saved-profile tests capture the Provider
revision before network work and commit capability/success fields only
with a same-transaction revision CAS. A result from endpoint/model A becomes
`stale-provider-revision` if the same profile ID changed to B and cannot mutate B
or cancel B's Runs. HTTP is accepted only for `localhost`, `127.0.0.1`, or `::1`
Ollama endpoints. URL credentials,
queries, fragments, remote plain HTTP, missing model IDs, and invalid timeouts
are rejected before model construction.

Remote disclosure is bound to the Run's immutable
`Space + profile + destination identity`, where the destination identity hashes
Provider kind and the canonical effective endpoint. A separate Provider
revision identity also binds the model, Keychain reference, context window,
timeout, and tested capabilities used by the Run. Editing any run-relevant
field or changing a Space override transactionally cancels stale persisted runs,
supersedes their pending outputs, advances the session generation, and makes an
old destination consent inapplicable to a new endpoint. Disclosure confirmation
accepts a Run ID and never re-resolves a mutable profile before recording consent.

The pinned Provider SDKs construct their own default `URLSession` and expose no
session-injection API. Under a construction lock, OneReader temporarily swaps
the default-configuration getter only while one SDK model is synchronously
created, then restores it before returning. That SDK receives the guard protocol
and an opaque per-session scope token; ordinary default sessions and Source
fetchers remain unchanged. The model instance retains a lease for exactly one validated
scheme/host/port/base-path scope. Requests outside the scope, requests after
lease expiry, and every redirect fail closed. Allowed requests use a
non-caching ephemeral inner session with custom protocols disabled. SDK
failures cross back into the runtime only as redacted categories. The transport
also counts actual response-body bytes across every callback and cancels HTTP,
NDJSON, or SSE after the 1 MiB per-response raw ceiling; a declared oversized
body is rejected before delivery. Connection probes additionally apply that
1 MiB ceiling cumulatively across every model response, explicit response-token
options, and a 4 KiB logical streaming snapshot bound.

The Apple bridge keeps native Foundation Models behind the same SwiftAgent
`LanguageModel` contract. It serializes a trust-separated JSON request with
`hostInstructions`, `hostRequests`, `registeredTools`, `assistantState`, and
`untrustedEvidence`; Source/tool output cannot share the host-owned instruction
channel. Its separate native instruction requires a small JSON response/tool
envelope and rejects every unregistered tool name.

## Tool and data boundary

The registry exposes exactly seven read-only tools:

- `listSources`
- `inspectCapabilities`
- `listContent`
- `readFragment`
- `searchContent`
- `resolveLocator`
- `inspectPresentation`

Every Source result is wrapped with `trust=untrusted-source-data` and an
evidence-only instruction. Tool calls are limited to the current Space and
the run's exact Snapshot manifest. The manifest is rechecked before every tool
touches Source bytes or Artifacts. Locators supplied to list/read/presentation
must match the installed plan exactly; Resolve may take a historical Locator
but its target must be the Source's manifest-bound current Snapshot. This
prevents another Space or stale revision from becoming accidental model
context. Adapter/tool failures are converted to fixed error categories before
SwiftAgent can serialize them, so managed paths, Source text, and notes cannot
escape through error strings.

Individual searches return at most 20 hits and reads at most 16K characters.
At most four read-only calls execute concurrently. SwiftAgent reinjects their
results in original call order. Results above 64 KiB become immutable,
digest-addressed Artifacts, and `readFragment` pages only an Artifact belonging
to the current run.

## Budgets and context projection

The default run allows 12 model rounds and 64 tool calls. Prompt projection uses
70 percent of the validated configured context window, or 70 percent of 32K
when unknown. Context windows outside 1,024...2,000,000 are rejected. Main and
summary generation receive an explicit `maximumResponseTokens`; the host also
checks every complete response and the provider-normalized accumulation of all
streamed delta entries against a 64 KiB logical byte ceiling. Anthropic's
cumulative snapshots are exact-byte prefix-checked and reduced to deltas while
their full raw encoded size still contributes to transport telemetry. Combining
marks and ZWJ sequences therefore remain byte-stable, while Unicode canonical
equivalence cannot conceal a rewritten prefix. It separately caps the
cumulative encoded stream entries and raw transport body, so arbitrarily many
small deltas cannot bypass the limit. The final aggregated entry—not merely the
last delta—is persisted in the transcript and context snapshot. A Provider that
ignores its option is rejected. The projected transcript is measured again
after every compression stage and fails closed when the protected tail or
bounded model summary still exceeds the hard target.
Every UTF-8 byte is conservatively counted as at least one token, plus explicit
structure overhead; code-heavy or adversarial ASCII therefore cannot exploit a
bytes-per-token heuristic. A model-summary input is split into bounded chunks,
and the encoded transcript for every chunk is checked against the same hard
input budget before the Provider is called.
The projection applies, in order:

1. duplicate Observation digest removal;
2. replacement of old large tool results with Artifact handles;
3. folding completed phases into structured facts;
4. a bounded model summary only when still required.

The summarization call consumes the same model-round budget. Each call persists
actual input bytes, complete-response or cumulative streamed-entry bytes,
duration, outcome, and conservative token upper bounds; these host measurements
are audit and budget data, not Provider billing usage. A model call that fails
after output was observed still records those bytes. Its last aggregated entry
is appended as a `partialFailure` audit transcript record, while the mutable
resumable transcript remains unchanged. Summary tool-call responses and raw
transport overflows follow the same failure-audit rule. Metric and partial
record are inserted atomically with a database-assigned transcript sequence.
Cancellation is persisted before the in-flight task is signalled. If a Provider
ignores that signal and generation, streaming, or summary work returns normally,
the audit transaction resolves the nominal success/failure to `cancelled`, stores
the observed partial entry, and prevents it from reaching the mutable transcript.
A matching cancelled Run may complete this immutable audit after the mutable
session advances to a replacement generation, so closing the Activity recorder
cannot lose cancellation evidence. Oversized partial entries are replaced by a
bounded SHA-256/byte-count marker while the metric retains the full observed
byte count.
The mutable session row holds the latest projection, while every model boundary
also appends an immutable run-bound snapshot containing the full transcript,
actual projected transcript, and projection audit. Starting or explicitly
resuming a normal run preserves prior session context and never mutates earlier
snapshots. Source/Provider invalidation may clear only the mutable projection;
it cannot delete historical snapshots.

## Host validation

Models return typed envelopes only. The host freshly reruns deterministic probe
selection before accepting an adapter proposal, derives confidence and
capability routing from those fresh results, and assigns all persisted IDs and
timestamps. A model cannot promote the 0.1 Quick Look fallback by claiming 0.9
confidence. Automatic adoption additionally requires the deterministic primary
and preservation of baseline capabilities; alternative combinations remain
user-confirmed candidates. The host rejects unknown or unreadable adapter combinations,
incomplete capability routes, inflated confidence, invented probe evidence,
non-current revisions, Locators without saved Observations, graph units without
fragments, invalid relations, stale graph bases, stale plan snapshot sets, and
answer quotations whose exact UTF-8 byte sequence is not present in the saved
Observation.

An accepted GraphPatch is materialized as a new graph version. Every final
unit—including unchanged units inherited from a base graph—is revalidated, so
a refreshed Source cannot leave historical fragments masquerading as current.
Reading plans bind one exact graph/version and remain frozen.

Validation never writes. It returns an `AgentDomainMutation`; one GRDB write
transaction then compares the active session generation and run state, checks
the exact manifest again, applies the domain mutation, saves the structured
output, transitions the run, and appends the terminal Activity event. Any
failure rolls all of those effects back together.

## Dependency compatibility

`SwiftAgent` is locked to 2.0.1 with its `OpenFoundationModels` trait and
`AnyFoundationModels` to 0.5.5 with only Claude, Response, and Ollama traits.
SwiftAgent 2.0.1 declares an unused peer-connectivity package for a different
product; that package currently resolves to a Swift 6.4-only manifest, while
OneReader's release toolchain is Swift tools 6.2/Xcode 26.6. The readable
source-only shim under `Vendor/` exposes only that unused product.
`scripts/bootstrap-dependencies.sh` deterministically creates an ignored local
Git mirror tagged 0.2.5 and configures SwiftPM before resolution. Mirror creation
ignores system/global Git configuration, disables signing, hooks, attributes,
and line-ending conversion, then verifies the exact generated HEAD/tag and a
clean tree. CI and Release resolve the package graph first, then run
`check-dependency-lock.py` and prove the committed lock remains unchanged after
resolution, build, and packaging. This avoids a same-identity path override (which SwiftPM warns
will become an error) and contains no copied peer implementation. No
peer-connectivity, AgentTools, Bash, Write, Edit, Dispatch, MCP, or Skills code
is linked into OneReader.

The runtime design is a clean-room behavioral implementation informed by the
documented session/turn, streaming, cancellation, transcript, and compaction
patterns of Claude Code. It does not copy the local Claude Code source or treat
third-party reverse-engineering notes as an official implementation contract.
