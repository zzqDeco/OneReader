# macOS 26 Release

Status: Active

Branch: `ci/macos26-release`

Milestone: `v0.2.0`

Dependencies: [Native reader workspace](native-reader-workspace.plan.md)

## Summary

Make one validation path authoritative for local development, pull requests,
and exact-tag release builds, then package a sandboxed Developer Preview with
auditable versions and digests.

## User Behavior

- Download DMG or ZIP artifacts whose manifest identifies the exact source,
  dependency lock, schemas, toolchain, signature, and checksums.
- Receive a clearly labeled unnotarized prerelease rather than an artifact that
  implies App Store or notarization trust.

## Contracts/Migration

- Require annotated `vX.Y.Z` tags at `origin/main` tip with matching Info.plist.
- Keep workflow permissions read-only by default and reject release overwrite.
- Validate app sandbox entitlements and ad-hoc signature from the exact tag.

## Implementation

- Pin Swift tools 6.2, macOS 26.1, package dependencies, runner `macos-26`, and
  Xcode 26.6.
- Add unified validation, entitlement checks, DMG/ZIP creation, checksums,
  release manifest, dry-run dispatch, concurrency, and release gates.

## Test Plan

Exercise local validation, dependency-lock drift, doc index, tests, release
build, Sandbox package, codesign verification, manifest schema, tag rejection,
version mismatch, dry run, and duplicate-release refusal without LLM secrets.

## Acceptance Evidence

Pending: exact workflow revision, local validation output, codesign details,
artifact checksums, manifest, and documented branch-protection settings.

## Non-goals

Developer ID distribution, notarization, App Store submission, automatic push,
automatic release before a remote exists, Intel binary, and real Provider calls.

## Delivery Checklist

- [ ] User behavior implemented
- [ ] Contracts and migration implemented
- [ ] Focused tests pass
- [ ] Unified validation passes
- [ ] Native acceptance recorded
- [ ] Current-state and source docs synchronized
- [ ] Branch merged into `dev`
- [ ] Status changed to Delivered
