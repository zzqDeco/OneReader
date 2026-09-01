# OneReader

OneReader is a native macOS all-in-one reader that turns heterogeneous material
into a managed, searchable, locatable reading space. It starts with an empty
Library: no example book, downloaded document, account, or model is required.

The v0.2 work is organized as independently verified slices. The Library core
already owns immutable managed snapshots and versioned SQLite storage; source
adapters, the optional Reading Agent, the unified workspace, and release gates
are tracked in [the plan index](plan/README.md).

## Run locally

Requirements:

- macOS 26.1 or newer
- Xcode 26.6 with Swift tools 6.2
- Network access only when importing a remote source or using a remote Provider

```bash
scripts/bootstrap-dependencies.sh
swift run OneReader
```

Run the bootstrap once before opening `Package.swift` in Xcode, then use the
`OneReader` executable scheme. It configures an ignored local mirror for one
unused SwiftAgent transitive product whose upstream manifest requires a newer
Swift tools version; it does not download or link that peer implementation.

## Validate

```bash
scripts/validate-native.sh
```

An ad-hoc signed, sandboxed Developer Preview app bundle is written to
`dist/OneReader.app`.

## Current architecture

- Native SwiftUI/AppKit application; no web shell, Electron, or JavaScript runtime
- Empty Library with managed storage under Application Support
- GRDB migrations, WAL, live FTS5 observation search, and immutable source snapshots
- Atomic local/remote import, SHA-256 or directory-tree revision, and content deduplication
- PDF, EPUB, Markdown, text, code, HTML, web, directory/repository, and Quick Look adapters
- Public GitHub exact-SHA snapshots and bounded same-origin webpage snapshots
- PDFKit, native selectable text/code, sanitized read-only WebKit, and Quick Look presentations
- Injectable 4 GiB confirmation/2 GiB reserve policy and Trash-based managed removal
- Legacy progress backup under `Legacy/` without false identity migration
- Source, adapter, locator, evidence, graph, annotation, and Agent audit contracts
- Optional single Reading Agent with seven read-only tools and host-owned commits
- Dedicated fail-closed Provider sessions, endpoint-bound disclosure, and Keychain secrets
- Snapshot-bound locators with explicit current, relocated, or orphaned resolution

## Project management

- `main`: stable and releasable
- `dev`: integration
- topic branches: cut from `dev` and merged back by pull request
- `doc/`: current engineering truth
- `plan/`: active and recently delivered implementation intent
- `doc/src/`: source-boundary notes mirroring important code paths

See [the development workflow](doc/branching.md), [current documentation](doc/README.md),
and [the plan index](plan/README.md).
