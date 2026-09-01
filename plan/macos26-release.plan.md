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

The latest full suite passes all 185 tests; the authoritative release gate owns production compilation,
Sandbox app packaging, codesign verification, exact entitlement inspection,
release-reference fixtures, and positive/negative entitlement fixtures. A
local dry run produces a verified DMG and ZIP, SHA-256 sidecars, and manifest
schema 1 carrying database schema 9, adapter schema 1, Agent runtime schema 5,
dependency-lock digest, toolchain, ad-hoc signing, Sandbox, and unnotarized
state.

Both workflows parse as YAML and pin official checkout/upload/download Actions
by commit. The release workflow keeps default permissions read-only, grants
`contents: write` only to the publish job, rejects release overwrite, and keeps
manual dispatch artifact-only. Repository protection settings are documented
but deliberately not mutated because this local repository has no remote.

## Non-goals

Developer ID distribution, notarization, App Store submission, automatic push,
automatic release before a remote exists, Intel binary, and real Provider calls.

## Delivery Checklist

- [x] User behavior implemented
- [x] Contracts and migration implemented
- [x] Focused tests pass
- [x] Unified validation passes
- [x] Native acceptance recorded
- [x] Current-state and source docs synchronized
- [x] Branch merged into `dev`
- [ ] Final Sol max review and regenerated exact-head artifacts accepted; status changed to Delivered
