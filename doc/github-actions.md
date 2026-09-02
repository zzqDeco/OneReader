# GitHub Actions

## CI

`.github/workflows/ci.yml` runs for:

- pushes to `main` and `dev`;
- pull requests targeting `main` or `dev`;
- manual dispatch.

Ordinary topic-branch pushes do not create duplicate hosted builds. Opening or
updating the pull request provides the required hosted signal.

The workflow uses commit-pinned official checkout and artifact actions, then
delegates repository verification to `scripts/validate-native.sh`. The same
script is the local and Release build gate. It:

1. checks out complete history;
2. selects Xcode 26.6 explicitly on the ARM64 `macos-26` image and reports the
   Swift/Xcode toolchain;
3. creates the deterministic ignored mirror for the pinned unused SwiftAgent
   peer product with system/global Git configuration, signing, hooks,
   attributes, and line-ending transforms disabled;
4. runs `swift package resolve`, then verifies the committed dependency versions,
   exact generated mirror revision, and a byte-unchanged `Package.resolved`;
5. verifies Apple platform metadata, all 28 AppIcon slots, and that the checked
   Xcode project exactly regenerates from `project.yml`;
6. runs whitespace and documentation-index checks;
7. runs `swift test` and builds the SwiftPM release configuration;
8. assembles and verifies an ad-hoc signed, sandboxed macOS `.app` bundle;
9. builds the unsigned universal iPhone/iPad Simulator target with Xcode 26.6;
10. repeats the lock digest checks after every build/package phase;
11. validates release-ref rejection fixtures and schema metadata;
12. uploads separate macOS Developer Preview and iOS Simulator artifacts.

Both CI and Release install the official XcodeGen 2.45.3 release archive and
verify its pinned SHA-256 before use. The exact version, also encoded in
`project.yml` and enforced by the project-drift check, prevents a newer
Homebrew formula from silently changing the checked-in project. Concurrency
cancels superseded runs for the same pull request or branch. Permissions are
read-only and CI receives no Provider secret.

## Release

`.github/workflows/release.yml` runs for annotated semantic-version tags and
manual dry runs.

For a tag release it rejects:

- tags not matching `vX.Y.Z`;
- lightweight tags;
- a tag, checkout, or `origin/main` tip that is not the exact same commit;
- a version that does not match the app bundle metadata.

It repeats the authoritative native gate, then creates ad-hoc signed, sandboxed
Developer Preview DMG and ZIP artifacts, SHA-256 sidecars, and a JSON manifest
containing tag, exact commit, Swift/Xcode versions, dependency-lock digest,
database/adapter/agent schemas, and signing/notarization state. Manual dispatch
only uploads a dry-run bundle. Tag publication runs in a separate job with
`contents: write`, refuses to overwrite an existing Release, and publishes an
explicitly unnotarized prerelease.

## Repository settings

When the GitHub remote is created:

- keep `main` as the default branch;
- protect `main` and `dev`;
- disable force pushes;
- require pull requests;
- require the CI job;
- keep release creation restricted to tags on `main`.
