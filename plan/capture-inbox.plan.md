# Quick capture and reading inbox

Status: Active. Issue: #27. Base: `a3c5b24` (`dev`).

## Product contract

- Keep capture/import lifecycle separate from Reading Space organization.
- Space states are 待整理 / 在读 / 已读 / 归档. Existing and explicitly created
  Spaces stay 在读; a capture-created Space starts 待整理. Organization never
  changes source content, bookmarks, notes, history, or actual reading progress.
- Capture receipts are durable before showing 已接收. A receipt is not a download
  or indexing success. A queued URL remains waiting without network.
- Host import uses ManagedLibrary, existing acquisition policies and adapters.
  No provider, account, or new import pipeline is required.

## Implementation sequence

1. Add CaptureJob contracts, shared atomic handoff and schema v11. Cover durable
   receipt, idempotent claims/retries, cancellation and recovery with local tests.
2. Add host capture coordinator, persisted import receipt, and native Library
   inbox with search, retry/cancel, multi-select organization and direct reading.
3. Route macOS menu/paste/drop/open entry points through the same coordinator,
   retaining an explicit direct-open path. Add the universal iOS Share Extension
   for URL, PDF, EPUB, image, HTML, Markdown, plain text and source-code files.
4. Update documentation/source indexes and generated Xcode project; run bounded
   unit/static checks. Native/device acceptance is a separate integration gate.

## Atomic handoff and safety

- An App Group contains only versioned capture receipts, copied attachment
  payloads, and a small Space destination catalog, never SQLite, Keychain or the
  managed Library. Target group: `group.io.github.zzqDeco.OneReader.capture`.
- Write an attachment and a manifest into a private staging directory, then
  rename the directory into `ready/<UUID>`. Only completed directories are visible
  to the host. Host database upsert and job-ID import receipt make replay safe.
- Host acknowledges only after its database has durable job metadata and safe
  local staged content. An interrupted host resumes importing without creating a
  second Source/Space. Failed/cancelled jobs retain payloads for explicit retry.
- Bound attachments and batches, reject symbolic links and unsafe paths, enforce
  existing disk/file limits, and preserve explicit large-material confirmation.
- The Share Extension does not download URLs, perform indexing, invoke a model,
  open the host app, or promise background completion. It offers per-item errors.

## Verification and remaining gates

- Local tests use generated fixtures, fake network/session boundaries, temporary
  databases and isolated staging directories. Test all transaction boundaries,
  duplicate receipts, multiple attachments, disk limits and organization safety.
- Run dependency bootstrap first; worker `swift test` uses at most two jobs.
- No production Library/app, real documents/providers, new Simulator, signing
  portal mutations or Xcode/device tests while parallel feature work is active.
- Root integrates the four reserved migrations and runs platform builds and
  physical iPhone Safari/Files plus macOS light/dark/narrow/wide acceptance.
- App Group provisioning/signing must be verified on the actual development team;
  source entitlements alone do not prove device entitlement availability.

## Evidence

### Review follow-up: payload-bound receipt identity

- The initial receipt replay check compared path/size but not payload bytes.
  Harden the handoff with a streamed SHA-256 digest over every payload entry,
  including relative paths, file bytes and empty directory structure.
- Always stage and verify the incoming local payload before returning an
  existing receipt. Same-ID conflicts must preserve the original payload.
- Add optional digest metadata with receipt schema v2. Old local receipts
  without integrity metadata fail closed and retain their stored content;
  remote URL receipts keep URL-based idempotence.
- Add regressions for same ID/name/size with changed file bytes, changed nested
  directory bytes/structure, concurrent conflicts, tampered persisted content
  and digest-less legacy receipts. Run targeted tests with at most two jobs.
- 2026-10-13 follow-up verification: `swift test --jobs 2 --filter CaptureInboxTests`
  passes 26 tests with 0 failures. Share Extension iOS strict-concurrency/API
  typecheck, generated-project consistency, Apple metadata, documentation index
  and diff checks pass. No new database migration or capability changes.

- 2026-10-13: implementation complete in the isolated feature worktree.
- `swift test --jobs 2 --filter CaptureInboxTests`: 19 tests, 0 failures.
  Covers interruption/replay, cancellation fencing, shared handoff, partial
  invalid batches, offline retry, independent identities, capacity rollback,
  migration, reversible organization, and active-reader preservation.
- Share Extension passes Swift 6 strict-concurrency, application-extension-only
  API typechecking for arm64 iOS 26.1 against the installed iPhoneOS 27 SDK.
- Pinned XcodeGen 2.45.3 regenerated the project; project consistency, 28-slot
  Apple metadata validation, 80-file documentation index and diff whitespace
  checks pass. Release version and dependency pins are unchanged.
- Native UI, physical iPhone Safari/Files sharing, capability provisioning,
  integrated platform builds and CI remain root-owned acceptance gates.
