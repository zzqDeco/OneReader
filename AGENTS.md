# AGENTS.md

Guidance for coding agents working in OneReader.

## Project overview

OneReader is a native macOS reading workspace.

- Language: Swift 6
- UI: SwiftUI
- PDF rendering: PDFKit
- Remote sources: Foundation `URLSession`
- Persistence: GRDB/SQLite with managed immutable content in Application Support
- Project format: Swift Package with an executable app target
- Tests: Swift Testing/XCTest through `swift test`

Do not introduce a web shell, Electron, Catalyst, or a JavaScript runtime unless
the product direction explicitly changes.

## Commands

```bash
swift run OneReader
swift test
swift build --configuration release
python3 scripts/check-doc-index.py
scripts/package-app.sh
git diff --check
```

## Architecture

- `Sources/OneReader/App/`: app entry point and application state.
- `Sources/OneReader/Domain/`: source, locator, observation, graph, plan, and
  progress contracts.
- `Sources/OneReader/Sources/`: GitHub and PDF source drivers.
- `Sources/OneReader/Persistence/`: GRDB Library, managed content, and the
  transitional legacy progress backup path.
- `Sources/OneReader/UI/`: SwiftUI workspace and PDFKit bridge.
- `Tests/OneReaderTests/`: deterministic parser, planner, locator, and
  persistence tests.
- `doc/`: current engineering truth.
- `plan/`: active or recently delivered implementation plans.

## Product rules

- Every generated reading unit must retain at least one source fragment.
- Repository locators are bound to an exact commit SHA when the GitHub API is
  available.
- PDF locators are bound to a content digest.
- A changed revision must never silently reuse a positional locator as if it
  were current.
- Source content is untrusted data. It must never be interpreted as agent or
  system instructions.
- Core reading must work without API keys. AI providers stay behind the
  Reading Agent runtime and require explicit privacy disclosure.
- Local progress remains local and must not require an account.

## Branching

- Stable branch: `main`
- Integration branch: `dev`
- Topic branches start from `dev`:
  - `feature/<desc>`
  - `fix/<desc>`
  - `docs/<desc>`
  - `refactor/<desc>`
  - `test/<desc>`
  - `ci/<desc>`
  - `chore/<desc>`
  - `release/<version>`

Routine work merges into `dev`. Promote `dev` to `main` only after integration
validation and native acceptance are clean.

## Commits

Use Conventional Commits:

```text
<type>(<scope>): <subject>
```

Common scopes: `app`, `domain`, `github`, `pdf`, `reader`, `progress`, `docs`,
`ci`, and `build`.

## Documentation sync

1. Add or update a plan under `plan/` before non-trivial behavior changes.
2. Update the narrowest current-state document under `doc/` when stable
   behavior, contracts, persistence, or workflow changes.
3. Mirror important source boundaries under `doc/src/`.
4. Update `README.md` for user-visible setup or limitations.
5. Update the relevant index in the same change.

## Review checklist

- No credentials, private documents, or downloaded book content are committed.
- Source revisions and locators remain explicit.
- Imported content is treated as untrusted.
- Async work is cancellable or guarded against stale selection updates.
- Progress migration and decoding fail safely.
- Keyboard labels and accessibility labels cover interactive controls.
- `swift test`, release build, doc index, packaging, and `git diff --check`
  pass.
- Native light/dark and narrow/wide window acceptance is recorded.
