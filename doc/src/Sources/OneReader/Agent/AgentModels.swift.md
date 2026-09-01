# `Sources/OneReader/Agent/AgentModels.swift`

Defines Provider profiles, run requests, structured output envelopes, runtime
limits, transcript/context snapshot records, and model-call audit records.
Runtime defaults are hard host limits: 12 model rounds, 64 tool calls, four
concurrent reads, 20 search hits, 16 KiB reads, 70 percent prompt utilization,
16,384 response tokens, 64 KiB logical model output, and a 1 MiB per-response
raw Provider ceiling. Connection probes apply that raw ceiling cumulatively
across their full lease.

`AgentTokenUsage` is derived from host-observed bytes using a conservative token
upper bound and includes measured wall-clock duration. It is intentionally not
presented as Provider billing usage. Model-call records also carry an explicit
outcome, and transcript records distinguish complete entries from audit-only
partial failures. Oversized partial content is represented by a bounded digest
marker while the metric preserves the full observed-byte count. `AgentRun` binds immutable destination and
Provider-revision identities so mutable profile lookup cannot change the
authority of an existing Run.

`AgentRunRequest.pipeline` records host-owned pipeline provenance separately
from the task kind. The current `readingStructure` pipeline can therefore
resume from a persisted phase without treating a standalone evidence question
as permission to scout, construct a graph, or replace a route. The optional
field keeps requests persisted before this contract decodable; missing
provenance fails closed by scheduling no downstream phase.
