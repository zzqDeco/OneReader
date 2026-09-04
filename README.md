# OneReader

OneReader is a native Apple-platform all-in-one reader for macOS, iPhone, and
iPad. It turns heterogeneous material into a managed, searchable, locatable
reading space and starts with an empty Library: no example book, downloaded
document, account, or model is required.

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

The shared target remains iPad-capable, but v0.3.1 release acceptance is scoped
to macOS and a connected physical iPhone; physical iPad acceptance is deferred.

Run the bootstrap once before opening the project. It configures an ignored
local mirror for one
unused SwiftAgent transitive product whose upstream manifest requires a newer
Swift tools version; it does not download or link that peer implementation.

## Validate

```bash
scripts/validate-native.sh
```

An ad-hoc signed, sandboxed macOS Developer Preview is written to
`dist/OneReader.app`; the universal iPhone/iPad Simulator product is written
under `.onereader/DerivedData-iOS/`.

After validation, `scripts/package-release.sh` creates an unnotarized Developer
Preview DMG and ZIP with SHA-256 sidecars and `release-manifest.json`. It does
not publish, tag, or push anything.

## Current architecture

- Shared SwiftUI domain/application module with native AppKit and UIKit shells
- Checked-in Xcode project generated from `project.yml`; no Catalyst target
- Empty Library with per-installation managed storage under Application Support
- GRDB migrations, WAL, atomic FTS5 observation indexes, and immutable source snapshots
- Atomic local/remote import, SHA-256 or directory-tree revision, and content deduplication
- PDF, EPUB, Markdown, text, code, HTML, web, directory/repository, and Quick Look adapters
- Public GitHub exact-SHA snapshots and bounded same-origin webpage snapshots
- PDFKit, native selectable rich Markdown/text/code, sanitized read-only WebKit,
  and Quick Look presentations on macOS and UIKit
- Library/Space search with FTS5 plus a bounded Chinese substring fallback
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
