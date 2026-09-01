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

All five slices are implemented and integrated locally; `main` remains
unchanged for a separate promotion review. The latest `swift test` passes 191
tests, including the integrated Sol-review corrections. The unified native
gate additionally owns dependency, documentation, release-policy, entitlement,
production-build, Sandbox bundle, and codesign checks. Database schema 9,
adapter schema 1, and Agent runtime schema 5 are bound into the release
metadata and verified by test.

The ad-hoc signed app was exercised against generated fixtures and a managed
`time-as-a-friend` repository snapshot in compact and wide native layouts,
without a configured Provider. The release dry run generated a valid DMG and
ZIP with matching SHA-256 sidecars and manifest. Exact branch and artifact
identities are reported from the final clean tree rather than frozen into this
historical delivery plan.

## Non-goals

OCR, accounts, sync, collaboration, private GitHub login, arbitrary Git
servers, third-party adapters, MCP, Skills, sub-agents, shell access, model
controlled writes, App Store distribution, and notarization.

## Delivery Checklist

- [x] Historical MVP fast-forwarded to `dev` without touching `main`
- [x] Repository moved to `/Users/zhaoziqian/OneReader`
- [x] Pre-dependency free-space gate reached
- [x] Five slice plans delivered
- [x] Unified native acceptance passed
- [x] `dev` ready for a separate promotion pull request
- [ ] Final Sol max review accepted and status changed to Delivered
