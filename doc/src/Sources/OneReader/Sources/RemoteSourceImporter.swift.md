# `Sources/OneReader/Sources/RemoteSourceImporter.swift`

Owns host-side HTTPS, web snapshot, and public GitHub ingestion. It is outside
the Agent runtime and never receives Provider credentials.

Ordinary URLs are downloaded once and routed by response media type. HTML is
materialized as a managed directory with a versioned manifest, sanitized main
document input, and bounded same-origin image cache. Other documents are
committed as immutable managed files and left to deterministic probing.

Bounded bodies use the download-to-temporary-file path. A download delegate
cancels live transfers at the byte ceiling before they are mapped into memory;
cancellation is normalized to
`CancellationError` before any Library commit.

GitHub imports resolve the default branch to a full commit SHA through the
public API, download the exact codeload archive, validate/extract it without
symlinks or path escape, and commit the repository root through
`ManagedLibrary`. Ordinary URLs must resolve only to public addresses. Redirect
delegates restrict hops to the original HTTPS allowlisted host.
