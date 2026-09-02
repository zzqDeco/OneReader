# `Sources/OneReader/Agent/ReadingTools.swift`

Owns the seven read-only Agent tools, their argument bounds, Space/Snapshot
authorization, exact run-manifest check, untrusted-data envelope, and immutable
Artifact spill behavior.
Source tools require the current installed AdapterPlan. List/read/presentation
Locators must match that plan; Resolve accepts a historical Locator only when
the explicit target is the Source's current Snapshot.

`ReadingToolRuntime` in `SwiftAgentTools.swift` adds the shared model/tool
budgets, generation checks, four-permit cancellation-safe gate, transcript
records, ordered Activity events, and a fixed-category error boundary that
prevents underlying paths or Source content reaching the model. The tool
registry is closed and does not
import AgentTools or expose network, shell, write, dispatch, MCP, Skills, or
sub-agent operations.

The SwiftAgent wrapper derives Source/Snapshot/Adapter identity from validated
arguments or the Locator, hashes the Locator JSON, and records requested limits
plus the byte range actually returned to the model. It never records query,
body, path, or note text in Activity metadata.
