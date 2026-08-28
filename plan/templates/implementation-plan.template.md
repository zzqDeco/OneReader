# <Plan title>

Status: Active

Branch: `<topic-branch>`

Milestone: `<version-or-milestone>`

Dependencies: `<plan links or none>`

## Summary

- State the user-visible or engineering goal.
- State why it belongs in this slice.

## User Behavior

- Describe what the user can do and what feedback they receive.
- State degraded behavior when optional services are unavailable.

## Contracts/Migration

- Record API, schema, persistence, revision, locator, and trust boundaries.
- Describe migration, rollback, and compatibility behavior.

## Implementation

- Describe subsystem decisions.
- Describe subsystem decisions, changed modules, scripts, and docs.
- Identify ordering, cancellation, transactional, and failure behavior.

## Test Plan

- List focused tests, hosted CI, native acceptance, and documentation checks.
- Distinguish build proof, runtime proof, and visual proof.

## Acceptance Evidence

- Record exact commands, fixtures, native scenarios, and artifact locations.
- Leave evidence pending until it has actually been observed.

## Non-goals

- Record intentionally deferred work and boundaries that prevent scope creep.

## Delivery checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
