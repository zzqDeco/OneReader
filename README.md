# OneReader

OneReader is a native macOS reading workspace that turns heterogeneous material
into a navigable reading space. The first vertical slice supports public GitHub
book repositories and PDF documents, then projects them into stable reading
units, goal-specific routes, source evidence, and local progress.

The bundled demonstration opens
[`xiaolai/time-as-a-friend`](https://github.com/xiaolai/time-as-a-friend) as a
repository-organized book and can load its published third-edition PDF for
side-by-side reading. Repository text and the PDF remain at their original
public URLs; OneReader does not vendor the book into this repository.

## Run locally

Requirements:

- macOS 14 or newer
- Xcode 16 or newer with the Swift toolchain
- Network access for the default GitHub demonstration

```bash
swift run OneReader
```

You can also open `Package.swift` in Xcode and run the `OneReader` executable
scheme.

## Validate

```bash
swift test
swift build --configuration release
python3 scripts/check-doc-index.py
scripts/package-app.sh
git diff --check
```

The unsigned app bundle is written to `dist/OneReader.app`.

## Current MVP

- Native SwiftUI window, sidebar, reading surface, and route inspector
- GitHub repository discovery through public GitHub APIs and raw content URLs
- Native PDF rendering through PDFKit
- Source snapshots and revision-bound locators
- Deterministic reading-unit mapper behind an AI-ready protocol
- Quick, systematic, and review reading plans
- Local progress persisted under Application Support
- Light and dark appearance through system materials and semantic colors

## Project management

- `main`: stable and releasable
- `dev`: integration
- topic branches: cut from `dev` and merged back by pull request
- `doc/`: current engineering truth
- `plan/`: active and recently delivered implementation intent
- `doc/src/`: source-boundary notes mirroring important code paths

See [the development workflow](doc/branching.md), [current documentation](doc/README.md),
and [the plan index](plan/README.md).

