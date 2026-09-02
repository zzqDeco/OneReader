# Native Reader Workspace

Status: Delivered

Branch: `feature/native-reader-workspace`

Milestone: `v0.2.0`

Dependencies: [Reading Agent runtime](reading-agent-runtime.plan.md)

## Summary

Replace the source-type demo flow with a coherent Library and reading workspace
where content remains central and navigation, annotations, evidence, and Agent
activity support rather than displace reading.

## User Behavior

- Import through drag/drop, Open, URL paste, and Open With.
- Browse All Spaces, Recent, Processing, Favorites, and Space-specific Sources.
- Read through unified PDFKit, native text/Markdown/code, controlled WebKit, and
  Quick Look presentations with outline, route, search, and Inspector.
- Create bookmarks, highlights, notes, progress, history, and evidence jumps.

## Contracts/Migration

- Persist source position, unit completion, plan step, and reading history
  independently.
- Persist annotations only at capability-supported anchors and mark relocation
  as current, relocated, or orphaned after refresh.
- Never show search/highlight/AI citation controls for unsupported Quick Look.

## Implementation

- Build adaptive NavigationSplitView semantics, import coordination, Library
  cards/list, reading navigation, presentation registry, inspector, Settings,
  commands, focus management, themes, and accessibility.
- Connect large-import confirmation and managed-source removal to native sheets;
  removal invokes the Library Core Trash transaction and never deletes the
  user's original selected file or directory.
- Respect 900x650 and 1440x900, light/dark, Reduce Motion, VoiceOver, keyboard
  focus order, native typography, and explicit external-link handoff.

## Test Plan

Cover reducer/state behavior, annotation CRUD, three-layer progress, history,
search jumps, route freezing, refresh relocation, stale async selection, import
latency, commands, accessibility labels, and presentation capability gating.

## Acceptance Evidence

The latest `swift test` passes all 191 tests. The unified gate additionally owns
the dependency lock, documentation index, release-policy fixtures, entitlement fixtures, production build,
Sandbox app assembly, codesign verification, and exact entitlement inspection.
Focused coverage includes durable position restoration, indexed query-specific
jumps including PDF pages, Space generation isolation, Agent target routing,
immutable Source refresh and anchor relocation, pending frozen plans, atomic
observation index recovery, Quick Look capability gating, unsaved Provider
probes, outbound Fragment audit metadata, bounded WebKit resource streaming,
the schema-v8 local Source authorization lifecycle, schema-v9 plan-bound search
projection plus automatic v8 rebuild, syntax-bounded AST Markdown source/render
mapping with whole-leaf coverage fail-closure, Provider-invalidation cache
refresh, unavailable-leaf cross-selection rejection, and serialized WebKit stop.

The ad-hoc signed app was exercised with the managed `time-as-a-friend`
repository in 1440 x 900 and 900 x 650 layouts. It exposed the native Library,
source outline, selectable Chinese Markdown reading surface, explicit external
link action, annotation controls, and compact/wide Inspector. The full record is
owned by [v0.2 acceptance](../doc/acceptance.md).

## Non-goals

Chat-first home, web shell, Electron, Catalyst, cloud sync, accounts,
collaboration, OCR, and arbitrary embedded web browsing.

## Delivery Checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [x] Unified validation passes
- [x] Native acceptance recorded
- [x] Current-state and source docs synchronized
- [x] Branch merged into `dev`
- [x] Integrated Sol max review accepted and status changed to Delivered
