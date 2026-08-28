# OneReader v0.2 All-in-One Reader

Status: Active

Branch: `docs/all-in-one-reader-v1`

Milestone: `v0.2.0`

Dependencies: historical baseline [Native reading-space MVP](native-reading-space-mvp.plan.md)

## Summary

Replace the Repo/PDF demonstration with a Library-first native macOS reader.
Every imported source becomes an immutable managed snapshot, receives an
immediately readable deterministic adapter plan, and can later be explored by
one optional Reading Agent without making reading depend on a model.

## User Behavior

- Import files, folders, local repositories, public GitHub repositories, and
  web URLs through drag and drop, Open, paste, or Finder Open With.
- Begin reading as soon as a deterministic adapter is ready.
- Group one or more sources in a Reading Space and use unified outline, search,
  annotations, progress, history, routes, and evidence navigation.
- Keep all deterministic reading features when offline or without a Provider.
- Inspect Agent activity and evidence in a collapsible inspector instead of
  entering through a chat-first home screen.

## Contracts/Migration

- Replace closed Repo/PDF domain enums with revision-bound, adapter-scoped
  locators and capability protocols.
- Store metadata in a migrated GRDB database and immutable content under
  Application Support; keep API keys only in Keychain.
- Back up legacy `progress-v1.json` without pretending it maps to new objects.
- Never rewrite an old locator when a source revision changes.

## Implementation

Deliver five implementation slices in order, each from the latest `dev` and
fast-forwarded back only after its own tests and documentation are complete:

1. [Library core v2](library-core-v2.plan.md)
2. [Source adapters v2](source-adapters-v2.plan.md)
3. [Reading Agent runtime](reading-agent-runtime.plan.md)
4. [Native reader workspace](native-reader-workspace.plan.md)
5. [macOS 26 release](macos26-release.plan.md)

`main` stays unchanged until a separately reviewed `dev` to `main` promotion.

## Test Plan

- Run slice-focused unit and integration tests after every branch.
- Run one unified local validation command before each merge to `dev`.
- Use generated PDF, EPUB, HTML, Markdown, text, code, directory, and malicious
  fixtures; keep real books and cloned acceptance repositories uncommitted.
- Complete native light/dark, compact/wide, keyboard, VoiceOver, Reduce Motion,
  offline, restart, and stale-revision acceptance before promotion.

## Acceptance Evidence

Pending. Evidence must name exact commit, commands, test counts, package
signature/entitlements, database schema, fixtures, and native screenshots.

## Non-goals

OCR, accounts, sync, collaboration, private GitHub login, arbitrary Git
servers, third-party adapters, MCP, Skills, sub-agents, shell access, model
controlled writes, App Store distribution, and notarization.

## Delivery Checklist

- [x] Historical MVP fast-forwarded to `dev` without touching `main`
- [x] Repository moved to `/Users/zhaoziqian/OneReader`
- [x] Pre-dependency free-space gate reached
- [ ] Five slice plans delivered
- [ ] Unified native acceptance passed
- [ ] `dev` ready for a separate promotion pull request
- [ ] Status changed to Delivered
