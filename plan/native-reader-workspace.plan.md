# Native Reader Workspace

Status: Active

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
- Respect 900x650 and 1440x900, light/dark, Reduce Motion, VoiceOver, keyboard
  focus order, native typography, and explicit external-link handoff.

## Test Plan

Cover reducer/state behavior, annotation CRUD, three-layer progress, history,
search jumps, route freezing, refresh relocation, stale async selection, import
latency, commands, accessibility labels, and presentation capability gating.

## Acceptance Evidence

Pending: native screenshots, accessibility inspection, keyboard walkthrough,
long-document scroll, PDF zoom, restart recovery, and offline reading.

## Non-goals

Chat-first home, web shell, Electron, Catalyst, cloud sync, accounts,
collaboration, OCR, and arbitrary embedded web browsing.

## Delivery Checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
