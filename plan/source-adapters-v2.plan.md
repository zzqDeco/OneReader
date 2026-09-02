# Source Adapters v2

Status: Delivered

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

- 2026-08-30: `swift test` passed 61 tests. Generated fixtures cover PDF,
  EPUB, Markdown, text, code, HTML, directory composition, web snapshots,
  unknown-file Quick Look, and exact-SHA GitHub API/codeload behavior without
  relying on external network availability.
- EPUB/archive rejection tests cover traversal, symlink, case/Unicode
  collisions, declared expansion bombs, forged uncompressed-size metadata,
  actual written-byte ceilings, CRC validation, and abandoned/inactive derived
  cleanup.
- Remote tests cover live download limits, cancellation before commit,
  same-origin resources, HTTPS/public-address enforcement, and full 40-character
  GitHub commit persistence. Snapshot reads and FTS search remain available
  after the injected network session is gone.
- Locator tests cover exact Snapshot binding, current/relocated/orphaned states,
  and quote-based recomputation of stale Markdown line ranges.
- `swift build --configuration release`, the 49-file documentation index,
  `git diff --check`, Sandbox app packaging, and strict `codesign` verification
  passed.
- Integrated coverage now includes plan-bound search publication, recursive PDF
  page/EPUB spine indexing in directories, per-child EPUB derived roots, and a
  shared sanitizer/presentation resource root for nested directory HTML. The
  final exact-head Sol max review accepted the integrated candidate.
- Real-book interaction, screenshots, VoiceOver, and wide/narrow workspace
  acceptance remain explicitly owned by `feature/native-reader-workspace`.

## Non-goals

OCR, private GitHub, arbitrary Git servers, plugins, model-defined adapters,
JavaScript execution, and cross-origin resource loading.

## Delivery Checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [x] Unified validation passes
- [x] Native presentation packaging evidence recorded; workspace interaction deferred
- [x] Current-state and source docs synchronized
- [x] Branch merged into `dev` (local fast-forward; no remote configured)
- [x] Integrated Sol max review accepted and status changed to Delivered
