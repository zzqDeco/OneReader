# Reading Agent Runtime

Status: Active

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

- Persist ReadingAgentSession transcript and AgentRun/Event/Artifact schemas.
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

Pending: deterministic fake transcripts, persisted event sequence, rejected
patch samples, redaction assertions, and offline/no-provider behavior.

## Non-goals

Multiple agents, sub-agents, shell, arbitrary network, model file writes, MCP,
Skills, dispatch, hidden chain-of-thought display, and unattended network replay.

## Delivery Checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
