# Reader features integration

## Status

Active. Integrates issues #25, #26, #27 and #28 only.

## Branch

`feature/reader-tools-integration` from `dev` at `a3c5b241d8678c806cf2f4a5d04cf21c2f909063`.

## Milestone

Next reader feature increment; publication requires a separate decision.

## Dependencies

Capture/inbox, global notes/export, bilingual reading and local OCR topic branches. Preserve the
existing native reader, managed snapshots, position invariants and provider consent boundary.

## Summary

Implement four independent feature slices in isolated worktrees, then integrate shared models,
migrations, menus and reader hooks. Root owns final integration and evidence-bound acceptance.

## User Behavior

Collect into an inbox, organize and open sources, recover reading positions, annotate and export
notes, optionally translate real text, and locally recognize scanned pages without changing originals.

## Contracts / Migration

Reserved migrations: capture v11, notes v12, translation v13, OCR v14. Stable annotation IDs and
revision-specific locators connect features. Translation never guesses OCR and no feature bypasses
remote-data consent. Review final schema ordering, index identity and generated Xcode project.

## Implementation

1. Parallel narrow topic branches, plans and tests.
2. Integrate complete commits without discarding shared hooks.
3. Build/test combined migrations, import-to-read-to-annotate-to-export and OCR-to-translate paths.
4. Native isolated macOS acceptance, physical-iPhone regression and independent Sol max review.
5. Focused PRs with current-head CI. No automatic main promotion or release.

## Test Plan

Run the shared native validator and cross-feature tests; no real model secrets in CI. Record actual
device visibility separately from unit/build results. Preserve production apps, Library and sources.

## Acceptance Evidence

Pending. A feature remains open while its required implementation or acceptance is incomplete.

## Non-goals

iPad device acceptance, hosted Xcode migration, cloud sync, distribution/signing and v0.3.3 rework.

## Delivery Checklist

- [ ] Four feature slices implemented and individually tested.
- [ ] Integrated data migrations and native build tested.
- [ ] Cross-feature and physical/visible acceptance recorded.
- [ ] Sol max conclusions resolved and current-head CI green.
- [ ] Documentation, issue evidence and focused PR handoff complete.
