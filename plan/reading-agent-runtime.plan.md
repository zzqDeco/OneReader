# Reading Agent Runtime

Status: Delivered

Branch: `feature/reading-agent-runtime`

Milestone: `v0.2.0`

Dependencies: [Source adapters v2](source-adapters-v2.plan.md)

## Summary

Add one optional, auditable Reading Agent that explores registered read-only
capabilities and proposes validated adapter plans, graph patches, routes, and
evidence answers without owning persistence or file/network authority.

## User Behavior

- Reading continues without a Provider or when an Agent run fails.
- Configured runs stream factual phase/tool events into Activity.
- Low-confidence routing remains a suggestion; high-confidence validated output
  can be adopted without replacing an active frozen reading route.
- Interrupted work is visible after restart and resumes only on request.

## Contracts/Migration

- Persist the mutable ReadingAgentSession projection plus immutable, run-bound
  transcript/projection snapshots and AgentRun/Event/Artifact/model-call schemas.
- Accept only registered adapters, current snapshots, valid locators/fragments,
  evidence-backed graph nodes, and host-validated structured outputs.
- Keep secrets in Keychain and log only redacted metadata.

## Implementation

- Integrate pinned SwiftAgent/AnyFoundationModels traits behind a local runtime
  boundary; OneReader owns state machine, budget, concurrency, compression,
  cancellation, recovery, validation, and commits.
- Expose only seven read-only reading tools; serialize output reinjection by
  call order and spill large results to immutable Artifacts.

## Test Plan

Use fake models and URLProtocol to cover task types, confidence policy, 12-turn
and 64-call budgets, four-read concurrency, ordering, cancellation, late result
discard, interruption, artifact spill, four compression stages, injection
resistance, endpoint checks, redaction, timeouts, and stream failure.

## Acceptance Evidence

Current branch evidence includes deterministic fake transcripts, 147 passing
tests, ordered persisted events, rejected forged patches/quotes/Locators,
immutable endpoint/revision-bound disclosure, real SDK-session transport
isolation, redirect/lease/raw-response fail-closure, source-refresh and
Provider-edit/test races, reference-counted overlapping refresh leases,
append-only context snapshots, cumulative delta output telemetry, Artifact
spill, four-stage projection, adversarial context bounds, failure-partial audit
records, atomic cancellation audit after terminal transition or non-cooperative
normal return, exact UTF-8 Anthropic cumulative-prefix normalization, strict
streaming probe content, v5-to-v6 backfill/corruption coverage, bounded
rejected-output markers, cancel/start actor-reentrancy coverage, exact-once
Provider probes, cumulative probe transport, atomic Run-plus-queued-event
creation, terminal-event stream/database parity, post-terminal event rejection,
caller-cancelled startup cleanup, and redaction assertions. The
durable Run state also wins stream-completion semantics when an obsolete,
non-cooperative dependency returns a later local failure. Direct persistence
coverage proves that ordinary events cannot follow a terminal event. The
latest focused/full tests and unified release validation pass. The final Sol
Max review returned `PASS` with no High, Medium, or Low findings.

## Non-goals

Multiple agents, sub-agents, shell, arbitrary network, model file writes, MCP,
Skills, dispatch, hidden chain-of-thought display, and unattended network replay.

## Delivery Checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [x] Unified validation passes
- [x] Native acceptance recorded
- [x] Current-state and source docs synchronized
- [x] Branch merged into `dev`
- [x] Status changed to Delivered
