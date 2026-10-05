# OneReader v0.3.2 release notes

Version: **0.3.2 (5)**. Distribution: macOS Developer Preview.
These notes describe the release candidate; publication is confirmed only by
the [GitHub Release](https://github.com/zzqDeco/OneReader/releases/tag/v0.3.2).

## Reading fixes

- PDF remembers the actual visible position within a page, not just the page
  number. Capture follows native scrolling and validates rotated page geometry.
- PDF restores the saved viewport once the view has a usable layout.
- Native text, Markdown, and code retain line-relative viewport offsets across
  relayout and reopening, while explicit quote/selection navigation stays distinct.
- Existing HTML and EPUB reading-position recovery is covered by isolated
  physical-iPhone tests, including a second EPUB spine item.

## Validation and compatibility

Runtime source is unchanged from `df4ba5a70774848e6d60bf55b106185ca4b51c64`,
which passed 234 shared tests, 10 physical-iPhone interaction/recovery tests,
and 9 hosted layout tests, plus Sol max review. The release only adds version
metadata and delivery documentation after the recovery PR. Fresh hosted checks
still gate the release preparation, protected branch merges, and tag build.
See [acceptance](acceptance.md) for the exact historical evidence.

Database schema **9**, adapter schema **1**, and agent runtime schema **5** are
unchanged. No migration or cloud account is required. Existing Source snapshots,
annotations, and local progress remain local.

## Distribution limits

- macOS 26.1 or newer; ARM64 app in DMG and ZIP archives.
- Ad-hoc signed and sandboxed, **not notarized** and not Developer ID signed.
- SHA-256 sidecars and `release-manifest.json` record the exact tag, commit,
  pinned dependency lock, schema versions, and signing state.
- iPhone has physical acceptance evidence, but this release does not publish
  TestFlight or an App Store build. Physical iPad acceptance remains deferred.
- No new AI Provider live smoke, toolchain migration, or new source format is
  claimed by this maintenance release.
