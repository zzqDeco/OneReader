# OneReader

OneReader is a native Apple-platform all-in-one reader for macOS, iPhone, and
iPad. It turns heterogeneous material into a managed, searchable, locatable
reading space and starts with an empty Library: no example book, downloaded
document, account, or model is required.

Library 的“笔记中心”可跨空间查找书签、高亮和笔记，管理标签，并预览后导出
按来源分组的静态 Markdown。它完全离线工作；本机原文回链只适用于同一份
资料库，导出不会自动同步或覆盖外部编辑。详见[笔记中心](doc/notes-center.md)。

The Library core, source adapters, optional Reading Agent, and reading facts are
shared by all three platforms. SwiftUI adapts the shell to an iPhone drill-down
reader, an iPad split workspace, and a macOS window without introducing
Catalyst, a web shell, or a mobile-only schema.

## Run locally

Requirements:

- macOS, iOS, or iPadOS 26.1 or newer
- Xcode 26.6 with Swift tools 6.2
- XcodeGen 2.45.3 when regenerating the checked-in Xcode project
- Network access only when importing a remote source or using a remote Provider

```bash
scripts/bootstrap-dependencies.sh
swift run OneReaderApp
```

For iPhone or iPad, open `OneReader.xcodeproj` and run the `OneReader-iOS`
scheme, or build the unsigned universal Simulator app with:

```bash
scripts/build-ios-simulator.sh
```

The shared target remains iPad-capable, but v0.3.3 release acceptance is scoped
to macOS and a connected physical iPhone; physical iPad acceptance is deferred.

### Quick capture and inbox

Add Materials can collect files or HTTPS links into **待整理**, or import and
open them directly. The native Library exposes **待整理 / 在读 / 已读 / 归档**,
search, multi-selection, retry and cancellation. Archive preserves content,
notes and actual reading progress; marking read does not jump to the last page.
Links can be received offline and wait for a foreground app/network connection.

The universal OneReader-Share target adds iPhone/iPad system sharing for URLs,
PDF/EPUB, images, HTML, Markdown, text and code. “已接收” means its receipt and
attachment are saved, not that download/indexing has completed. Both app and
extension require a matching App Group provisioning capability; configure
ONEREADER_CAPTURE_APP_GROUP for the signing team. No account/provider is
required. Physical Share Sheet acceptance and release distribution remain
separate gates; see [capture and inbox](doc/capture-inbox.md).

On iPhone, Add Materials opens the system Files picker. Selected files are
copied into the managed Library and remain readable after relaunch. PDF reading
starts at fit width and supports native two-finger zoom plus zoom-out, zoom-in,
and fit-width buttons; the displayed percentage follows the live zoom.
Narrow pages in mixed-width PDFs are aligned on page navigation and explicit
fit width without recentering ordinary scroll, pinch or position updates.
ProMotion-capable iPhones are opted into higher refresh rates; native adaptive
frame pacing and the device's power/thermal settings still determine the actual
rate. The app does not force a permanent 120 Hz rendering loop.
PDF reading-position captures and position-only saves are isolated from
whole-reader UI refreshes. Other formats retain their existing refresh behavior;
exact progress still persists and restores across material types.
Intermittent PDF smoothness is checked separately from import/zoom correctness.

The reading-assistance 「双语」 tab supports explicit paragraph/selection translation
with the configured Reading Agent Provider. Original sources remain unchanged;
successful translations are cached for offline reading and can be deleted or
retried independently. Remote use requires the existing data-disclosure approval.
Machine translation is not original evidence; review terminology, numbers and
negation. Scanned material needs valid OCR text first. See [bilingual reading](doc/bilingual-reading.md).

The local OCR feature adds explicit on-device recognition for scanned PDF pages and
single JPEG/PNG/HEIC images. Recognition results retain page regions and immutable versions;
native text remains preferred, and old notes are not rewritten. See [OCR behavior and limits](doc/local-ocr.md)
and [pending acceptance](plan/local-ocr.plan.md) before treating the feature as device-validated.

Run the bootstrap once before opening the project. It configures an ignored
local mirror for one
unused SwiftAgent transitive product whose upstream manifest requires a newer
Swift tools version; it does not download or link that peer implementation.

## Validate

```bash
scripts/validate-native.sh
```

To run the dedicated file-picker and PDF-zoom regressions on a connected,
unlocked physical iPhone:

```bash
ONEREADER_IOS_DEVICE_ID=<device-udid> \
ONEREADER_DEVELOPMENT_TEAM=<local-team-id> \
scripts/test-ios-device-import-zoom.sh
```

This installs an independent `OneReader Fix Preview` application and uses a
UUID-isolated test Library. It does not replace the production app or open its
Library, and it does not create or boot a Simulator. Results and screenshots
remain under the ignored `.onereader/acceptance/ios-import-pdf-zoom/` directory.
Set `ONEREADER_IOS_TEST_ALL=1` to include existing cross-format position recovery
and Library/text/Markdown/code touch regressions in the same isolated app.

The real 252-page public-book case is explicit local-only acceptance. Seed an
unchanged copy as `Documents/Release Public Book.pdf` in the independent
`io.github.zzqDeco.OneReader.ImportZoomAcceptance` app, then pass
`ONEREADER_IOS_PUBLIC_PDF_TEST=YES` to the device script (or as an xcodebuild
setting). It verifies the actual mounted
page count, first page, pinch/buttons, scrolling and relaunch. Without this
opt-in the public-book case is skipped; a release acceptance run must explicitly
enable it and report no skipped required case. Never commit the input PDF.

An ad-hoc signed, sandboxed macOS Developer Preview is written to
`dist/OneReader.app`; the universal iPhone/iPad Simulator product is written
under `.onereader/DerivedData-iOS/`.

After validation, `scripts/package-release.sh` creates an unnotarized Developer
Preview DMG and ZIP with SHA-256 sidecars and `release-manifest.json`. It does
not publish, tag, or push anything.

## Current architecture

The published v0.3.2 Developer Preview focuses on cross-format reading-position recovery:
PDF within-page viewports and layout-aware native text/Markdown restoration.
See the [release notes](doc/release-v0.3.2.md) for evidence and distribution
boundaries. It remains ad-hoc signed and unnotarized.
The v0.3.3 candidate repairs Markdown paragraph indexing and rebuilds
old derived search data without rewriting notes or reading positions. This fix
is not included in the published v0.3.2 binaries.

The PDF maintenance slice also restores native first-page/EPUB-spine order and
retains macOS zoomed-PDF horizontal viewport placement, including mixed-width
documents. Existing saved positions are preserved; these repairs are not in
the published v0.3.2 binaries. See [reader behavior](doc/reader-workspace.md) and
the [v0.3.3 candidate notes](doc/release-v0.3.3.md). Publication is gated separately
from candidate validation; prior releases remain immutable.

- Shared SwiftUI domain/application module with native AppKit and UIKit shells
- Checked-in Xcode project generated from `project.yml`; no Catalyst target
- Empty Library with per-installation managed storage under Application Support
- GRDB migrations, WAL, atomic FTS5 observation indexes, and immutable source snapshots
- Atomic local/remote import, SHA-256 or directory-tree revision, and content deduplication
- PDF, EPUB, Markdown, text, code, HTML, web, directory/repository, and Quick Look adapters
- Public GitHub exact-SHA snapshots and bounded same-origin webpage snapshots
- PDFKit, native selectable rich Markdown/text/code, sanitized read-only WebKit,
  and Quick Look presentations on macOS and UIKit
- Library/Space/Source search with full-text Markdown/text/code chunks, FTS5,
  overlap deduplication, and a bounded Chinese substring fallback
- Bookmarks, exact-quote highlights, notes, source/unit/plan progress, and history
- iPhone drill-down navigation plus iPad/macOS split workspace and Inspector
- Injectable 4 GiB confirmation/2 GiB reserve policy; macOS Trash and
  transaction-safe iOS sandbox removal
- Legacy progress backup under `Legacy/` without false identity migration
- Source, adapter, locator, evidence, graph, annotation, and Agent audit contracts
- Optional single Reading Agent with seven read-only tools and host-owned commits
- Dedicated fail-closed Provider sessions, endpoint-bound disclosure, and Keychain secrets
- Snapshot-bound locators with explicit current, relocated, or orphaned resolution
- Best-effort platform bookmarks for local Source refresh; managed snapshots
  remain readable without the original authorization
- One generated app icon system for macOS, iPhone, iPad, and App Store slots

## Project management

- `main`: stable and releasable
- `dev`: integration
- topic branches: cut from `dev` and merged back by pull request
- `doc/`: current engineering truth
- `plan/`: active and recently delivered implementation intent
- `doc/src/`: source-boundary notes mirroring important code paths

See [the development workflow](doc/branching.md), [current documentation](doc/README.md),
and [the plan index](plan/README.md).

## License

OneReader is licensed under the [Apache License 2.0](LICENSE). Dependency
licenses and binary attribution behavior are documented in
[third-party notices](THIRD_PARTY_NOTICES.md) and the
[licensing contract](doc/licensing.md).
