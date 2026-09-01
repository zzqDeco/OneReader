# GitHub Actions

## CI

`.github/workflows/ci.yml` runs for:

- pushes to `main` and `dev`;
- pull requests targeting `main` or `dev`;
- manual dispatch.

Ordinary topic-branch pushes do not create duplicate hosted builds. Opening or
updating the pull request provides the required hosted signal.

The workflow:

1. checks out complete history;
2. selects Xcode 26.6 explicitly on the ARM64 `macos-26` image and reports the
   Swift/Xcode toolchain;
3. creates the deterministic ignored mirror for the pinned unused SwiftAgent
   peer product with system/global Git configuration, signing, hooks,
   attributes, and line-ending transforms disabled;
4. runs `swift package resolve`, then verifies the committed dependency versions,
   exact generated mirror revision, and a byte-unchanged `Package.resolved`;
5. runs whitespace and documentation-index checks;
6. runs `swift test`;
7. builds the release configuration;
8. assembles and verifies an ad-hoc signed, sandboxed `.app` bundle;
9. repeats the lock checker and tracked-file diff after Release build and again
   after app packaging;
10. uploads the bundle as a short-lived build artifact.

Concurrency cancels superseded runs for the same pull request or branch.
Permissions are read-only.

## Release

`.github/workflows/release.yml` runs for annotated semantic-version tags and
manual dry runs.

For a tag release it rejects:

- tags not matching `vX.Y.Z`;
- lightweight tags;
- commits not reachable from `origin/main`;
- a version that does not match the app bundle metadata.

It resolves first, validates the same dependency lock and mirror revision, then
repeats tests and Release build. It rechecks that resolution/build/package never
rewrote `Package.resolved`, creates an ad-hoc signed, sandboxed Developer Preview
ZIP and SHA-256 checksum, and publishes a GitHub prerelease. The release notes
state that Developer ID signing and notarization are not yet provided.

## Repository settings

When the GitHub remote is created:

- keep `main` as the default branch;
- protect `main` and `dev`;
- disable force pushes;
- require pull requests;
- require the CI job;
- keep release creation restricted to tags on `main`.
