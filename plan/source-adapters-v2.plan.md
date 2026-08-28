# Source Adapters v2

Status: Active

Branch: `feature/source-adapters-v2`

Milestone: `v0.2.0`

Dependencies: [Library core v2](library-core-v2.plan.md)

## Summary

Provide deterministic, composable adapters that make every v1 source readable
without a model and expose only capabilities they can actually support.

## User Behavior

- Open PDF, EPUB, Markdown, text, HTML, code, web snapshots, directories, local
  Git repositories, and public GitHub repositories on one reading surface.
- Search source content and jump to revision-bound results.
- See a clear Quick Look capability limit for unknown files.

## Contracts/Migration

- Split Probe, Revision, List, Read, Search, Render, and Resolve protocols.
- Route capabilities through AdapterPlan with probe evidence and confidence.
- Bind locators to source, snapshot, adapter, schema, structural path, quote,
  and fingerprint; never reinterpret a stale positional locator as current.

## Implementation

- Add AdapterRegistry, deterministic routing, format adapters, directory
  composition, secure EPUB extraction, HTML sanitization, controlled WebKit
  presentation, Quick Look fallback, FTS indexing, and locator resolution.
- Replace legacy URL-derived PDF/Repo identities with the UUID Source and
  Snapshot identities committed by ManagedLibrary; migrate compatible progress
  only through validated Locators, and make Observation content references
  artifact-capable rather than inline-only.
- Keep Source data untrusted and network fetching outside the Agent runtime.

## Test Plan

Exercise every capability contract, locator revision invariants, EPUB traversal,
symlink and expansion limits, script stripping, redirects, resource boundaries,
FTS rebuilds, cancellation, Git exact SHA, and Quick Look limits.

## Acceptance Evidence

Pending: generated fixture matrix, public repository SHA, offline snapshot read,
search result jumps, and security rejection evidence.

## Non-goals

OCR, private GitHub, arbitrary Git servers, plugins, model-defined adapters,
JavaScript execution, and cross-origin resource loading.

## Delivery Checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
