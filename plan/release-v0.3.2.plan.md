# v0.3.2 Reading Recovery Release

Status: Delivered

Branch: `release/0.3.2`

Milestone: `v0.3.2`

Dependencies: [Cross-format reading recovery](cross-format-reading-recovery.plan.md)

## Summary

Deliver the accepted reading-position repairs as macOS Developer Preview
v0.3.2 (5), without adding runtime behavior or changing the tested dependencies.
Use protected pull requests for release preparation and `dev` to `main`
promotion, followed by an immutable annotated tag at the exact `main` tip.

## User Behavior

- PDF resumes at the saved within-page viewport, including rotated pages.
- Native text and Markdown restore their line-relative position after layout.
- EPUB and HTML retain the accepted visible-position recovery behavior.
- Reading remains available offline and without a model or account.
- The downloadable macOS app remains ad-hoc signed, sandboxed, and unnotarized.

## Contracts/Migration

- Version metadata changes from 0.3.1 (4) to 0.3.2 (5) for both native targets.
- Database schema 9, adapter schema 1, and agent runtime schema 5 do not change.
- Source files, immutable snapshots, and user Library data are not modified by
  release preparation or acceptance. Existing optional viewport fields remain
  backward compatible; there is no data migration in this release slice.
- Physical evidence belongs to runtime `df4ba5a`; compare source/test trees to
  that commit before reusing it. Fresh CI gates every release and merge head.

## Implementation

1. Merge reviewed PR #15 to `dev` and verify the resulting commit's CI.
2. Update `project.yml`, regenerate app metadata/project with XcodeGen 2.45.3,
   record release notes, and close the merged recovery plan.
3. Review and merge release preparation through a PR to `dev`; validate its
   integration commit, then promote `dev` to `main` through a separate PR.
4. After exact-main validation, create annotated `v0.3.2` at that commit and
   let Release rebuild, package, and publish the Developer Preview.
5. Download the published DMG/ZIP and manifest, verify hashes/signatures/version
   and schema metadata, and smoke-test the downloaded app without changing the
   production Library. Keep publication evidence local and on GitHub so the
   tagged commit does not need a self-referential evidence edit.

## Test Plan

- Run lightweight metadata, project-drift, docs, and release-policy checks
  locally. Run the complete `scripts/validate-native.sh` gate on exact-head
  hosted CI and again in Release; no Simulator is booted.
- Require current-head Sol max review and protected-branch CI without bypass.
- Reuse the recorded 234 shared, 10 physical interaction/recovery, and 9 hosted
  iPhone layout passes only after verifying unchanged runtime/test source.
- Check tag type, exact main ancestry, version/build, dependency-lock digest,
  archive hashes, Sandbox entitlements, schema versions, and license files.
- Keep downloaded-product launch/read smoke evidence separate from prior
  physical-device tests; do not infer interaction success from a running process.

## Acceptance Evidence

PR [#15](https://github.com/zzqDeco/OneReader/pull/15) merged to `dev` as
`e0ca3b06ad0bcd6cb7ba879632a77694f3dbff18`. Its exact-head check was green
before merge. Historical physical recovery evidence is in
[acceptance](../doc/acceptance.md).

Local dependency-lock (28 pins), documentation-index (65 Markdown files),
Apple metadata (28 icon slots), generated-project drift, release-tag rejection,
entitlement rejection, plist lint, and whitespace checks pass. Runtime/test
source, dependency pins, workflow definitions, and schema metadata are unchanged
from the accepted runtime. Local free space is approximately 6.4 GiB; no new
dependency resolution or full local rebuild is attempted. An old build-cache
cleanup was rejected by the host safety policy and removed nothing; authoritative
rebuilds run on hosted workers. Physical evidence is retained locally.

Final delivery (2026-10-06; remote state rechecked 2026-10-07):

- Preparation [#16](https://github.com/zzqDeco/OneReader/pull/16), ancestry-only
  [#18](https://github.com/zzqDeco/OneReader/pull/18), and promotion
  [#17](https://github.com/zzqDeco/OneReader/pull/17) passed protected gates and
  merged. Sol max review approved without blockers.
- Exact main `d189d2cc5d91ed86e3bb66ba69931b411fa18aa6` passed
  [CI 37439997983](https://github.com/zzqDeco/OneReader/actions/runs/37439997983).
  Annotated tag `v0.3.2` at that commit passed
  [Release 37442270980](https://github.com/zzqDeco/OneReader/actions/runs/37442270980).
  Both rebuilds recorded 234 shared tests, zero failures, and Sandbox validation.
- The [published prerelease](https://github.com/zzqDeco/OneReader/releases/tag/v0.3.2)
  has all six assets. Original downloads passed checksum, manifest, strict
  signature/entitlement, license, and read-only DMG/ZIP equality checks.
- An isolated re-signed copy passed ordinary launch/import and source-identity
  persistence across process restart. This does not prove visible scroll
  recovery: macOS Accessibility was denied, so no new visual pass is claimed.
  Production Library hashes were unchanged; no phone was used in this gate.
- [#14](https://github.com/zzqDeco/OneReader/issues/14) and milestone v0.3.2
  closed. The separately confirmed paragraph-search defect remains tracked in
  [#19](https://github.com/zzqDeco/OneReader/issues/19) and the next repair plan;
  existing release notes disclose it. No tag or release asset was overwritten.

## Non-goals

New reader behavior, dependency/toolchain upgrades, AI Provider calls, iPad
physical acceptance, TestFlight/App Store distribution, Developer ID signing,
notarization, cloud sync, and modifying the real Library.

## Delivery Checklist

- [x] Reviewed reading recovery PR merged into `dev`
- [x] Version metadata and release notes prepared
- [x] Local metadata and release-policy checks pass
- [x] Sol max review passes
- [x] Release preparation and promotion PRs pass exact-head checks
- [x] `main` integration CI passes
- [x] Exact-main annotated tag publishes successfully
- [x] Downloaded artifacts verified and isolated smoke recorded
- [x] Milestone/issue closed after verified delivery

Closed in the subsequent search-repair documentation slice, without rewriting
the immutable release tag.
