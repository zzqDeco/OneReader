# `Sources/OneReader/Agent/ReadingAgentRuntime.swift`

Owns one `ReadingAgentSession` actor per Reading Space and the bounded
single-turn lifecycle. It creates durable runs, generation plus exact Snapshot
manifest tokens, event streams, budgets, tool runtimes, Provider drivers,
validation, and terminal state without giving the model persistence authority.
Every Run captures immutable Provider destination/revision identities before it
is inserted.

Restart recovery is explicit: database initialization marks incomplete runs
interrupted with an audit event, and `resume` creates one compare-and-swap
linked new run; a parent cannot be resumed twice. Remote
disclosure waits may resume after acknowledgment. Low-confidence adapter
candidates instead use dedicated local confirm/dismiss methods, including after
restart; a newer run cancels all older active or waiting choices. Source
revision orchestration atomically acquires a unique, reference-counted shared
lease for every attached Space, cancels in-memory tasks, advances the immutable
Snapshot and durable generation, synchronizes actor clocks, and only then
releases that lease. Run insertion is serialized through the same barrier, and
overlapping refreshes remain blocked until their final lease ends.

Cancellation captures and signals only the task associated with the old Run
before the session actor suspends. Each start attempt also owns a token checked
after every suspension and immediately before task installation. Caller task
cancellation uses the same checks. Cancellation or a newer concurrent start
invalidates that token; a stale/cancelled attempt terminalizes any persisted
queued Run and cannot invoke a Provider, reread, or overwrite the replacement
task. Run creation receives the queued event that persistence inserted in the
same transaction and publishes that durable event instead of racing a second
event write.

Every terminal path records a redacted category and leaves deterministic
reading available. Cancellation, generation, and manifest invalidation are
checked again after model, tool, validator, and transaction boundaries so late
output cannot commit. Profile/override edits cancel stale durable Runs and their
Provider-binding checks prevent already-returning network work from committing.
When a local non-cancellation error loses its terminal CAS, the runtime reads the
durable Run state. Durable cancellation/interruption controls stream completion,
so a late secret/model/tool failure cannot appear after a cancelled Activity.
