# Quick capture and reading inbox

The source implementation adds a durable capture queue to the existing native
Library. It is independent of providers, accounts, OCR and translation. Native
iPhone Share Sheet and macOS interaction acceptance remain separate from unit
tests and project validation; no new release is implied by these changes.

## User flow

- Add Materials defaults to **收集到待整理**. A local file is copied before a
  receipt is acknowledged; an HTTPS URL is persisted without downloading.
- **导入后直接阅读** and macOS Command-O retain the existing direct-reading path.
  Option-Command-O collects files. Window drop, Open With and URL paste feed the
  same durable capture coordinator.
- The Library shows received, waiting, importing, preparing, readable, failed
  and cancelled tasks. Retry is explicit after an error; offline URLs stay
  waiting. Foreground activation also resumes queued tasks.
- Select multiple Spaces to change **待整理 / 在读 / 已读 / 归档**. Search matches
  Space titles, source names and capture titles. Archive is a reversible
  organization state, never a deletion or a progress reset.
- A completed capture can join another Space. The original Space and its
  annotations/history are preserved; a capture-created single-source inbox
  Space is archived. This is deliberately not a destructive transfer.

The reading_spaces.organization_state column is the only organization state.
Existing Spaces migrate to reading, as do direct imports. A new Space created
through capture starts inbox. A capture targeting an existing Space does not
change that Space's state. Marking read does not synthesize an end-page locator.

## iPhone / iPad Share Extension

The universal native OneReader-Share target receives HTTPS URLs, PDF, EPUB,
images, HTML, Markdown, text and source-code files. The extension lists every
attachment, including per-item errors for unsupported inputs. Its receive
budget is at most 20 items, 512 MiB per file and about 60 seconds total, with a
15-second timeout per provider. Larger files can be selected in the main app,
where the existing 4 GiB confirmation and 2 GiB free-space reserve apply.

The extension only loads attachments, copies payloads, writes receipts and
completes the request. It does not invoke the app, download URLs, index material,
run a model or claim background execution. File-provider temporary URLs are
consumed inside their completion handlers. Images are accepted as images, not
reported as OCR text. A standalone shared HTML/Markdown file contains only its
authorized attachment; external sidecars are not silently read by the extension.
Host-selected local files still use the existing sidecar inspector.

App and extension must have a matching App Group capability and provisioning
profile. ONEREADER_CAPTURE_APP_GROUP defaults to
group.io.github.zzqDeco.OneReader.capture; its Info.plist value drives container
lookup in both executables. An unavailable group produces an explicit failure,
not a false receipt. This source change does not register capabilities, obtain
certificates or change device security settings.

## Durable handoff and recovery

The App Group contains only Capture-v1/ready, Capture-v1/writing and a bounded
Space ID/title catalog. It never contains Library SQLite, managed snapshots,
provider configuration, Keychain contents or credentials.

Each CaptureReceipt has a version, UUID, source descriptor, relative payload
path, target Space, display name, byte count and creation time. Schema v2 local
receipts also carry a SHA-256 digest of the full payload tree: relative entry
names, entry kinds, file lengths/bytes and empty directories. A writer copies
into a private nonce directory, syncs payload/manifest, then atomically renames
the directory into ready/job-id. Only ready directories are visible.
Path traversal, symbolic links, over-budget files and unsupported URL schemes
are rejected; leaf file reads use O_NOFOLLOW. Logs never contain source text,
private URL parameters or full input paths.

A local replay always stages and hashes the candidate bytes before checking an
existing task ID. Identical path/length is not proof of identical content.
Existing payloads are revalidated against their recorded digest before lookup,
replay, adoption or acknowledgment. A conflict never overwrites the original
ready directory. Hashing is streamed in bounded chunks without a new dependency.
Legacy local receipts without a digest remain decodable but fail closed at the
payload boundary: keep the original copy and ask the user to share it again.
Legacy and current remote receipts retain exact-URL-based idempotence.

The host copies an incoming directory into its private Capture staging area,
then inserts capture_jobs, and only then acknowledges/removes the shared copy.
If any boundary is interrupted, replay is idempotent by job ID. A malformed
attachment is retained and does not block the other valid attachments.

A database claim token fences every attempt. ManagedLibrary.commitImport
atomically writes Source, Snapshot, Space membership and capture result IDs.
After a restart, an interrupted job with result IDs reuses those same IDs and
only prepares its adapter. It never imports a second Source. Deliberately
removed Sources are not resurrected. Cancellation invalidates the claim; it
does not delete an already committed source. Digest deduplication is still
owned by ManagedLibrary and never merges independent Source identity.

Once an adapter is ready, the job becomes ready and the host removes only its
acknowledged temporary payload. The database receipt remains. Cleanup failure
is retried on next startup. Failed or cancelled jobs keep their payloads for
retry. Incomplete writer directories are not guessed to be abandoned or
deleted by a different process.

## Verification boundary

CaptureInboxTests uses generated fixtures, temporary databases, fake network
responses and isolated staging. It covers offline acceptance/recovery, replay,
claim contention, interruption before/after import commit, cancellation,
partial batches, capacity/path limits, companion resources, migration and
organization preserving evidence/progress. Share code is also typechecked with
Swift 6 and application-extension API restrictions. These checks do not
replace a signed physical iPhone Safari/Files run or macOS light/dark and
narrow/wide accessibility acceptance.
