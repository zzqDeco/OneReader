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
2. reports the Swift/Xcode toolchain;
3. runs whitespace and documentation-index checks;
4. runs `swift test`;
5. builds the release configuration;
6. assembles an unsigned `.app` bundle;
7. uploads the bundle as a short-lived build artifact.

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

It then repeats tests, builds the release executable, creates an unsigned app
ZIP and SHA-256 checksum, and publishes a GitHub prerelease. The release notes
state that signing and notarization are not yet provided.

## Repository settings

When the GitHub remote is created:

- keep `main` as the default branch;
- protect `main` and `dev`;
- disable force pushes;
- require pull requests;
- require the CI job;
- keep release creation restricted to tags on `main`.

