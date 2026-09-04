# Licensing and third-party attribution

OneReader source code is available under the unmodified Apache License 2.0 in
[`LICENSE`](../LICENSE). Public repository visibility is no longer the basis
for reuse permission; Apache-2.0 is the explicit project license.

## Distribution contract

The macOS packager places the project license, third-party summary, and every
available upstream license/NOTICE file for linked dependencies in
`OneReader.app/Contents/Resources/`. DMG and ZIP artifacts therefore carry the
same attribution payload as the app bundle.

`release-manifest.json` records `license`, the SHA-256 of the project license,
and the SHA-256 of `THIRD_PARTY_NOTICES.md`. These values describe the exact
release commit and fail packaging when either source document is absent.

## Compatibility review

The locked runtime graph uses MIT and Apache-2.0-family terms, which are
compatible with distributing OneReader under Apache-2.0. The complete audited
matrix and two upstream metadata gaps are recorded in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

SwiftAgent 2.0.1 and AnyFoundationModels 0.5.5 declare MIT in their pinned
README files but do not include standalone license files. The release bundle
does not fabricate those missing texts. Treat this as an upstream attribution
quality gap to re-check before moving from an unnotarized Developer Preview to
a notarized stable binary.
