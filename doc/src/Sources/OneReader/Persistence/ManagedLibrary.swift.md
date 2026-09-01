# `Sources/OneReader/Persistence/ManagedLibrary.swift`

Owns local file/directory inspection, streaming SHA-256 and tree digests,
staging-copy verification, content-addressed storage, digest deduplication,
free-space enforcement, and the source/snapshot/Space commit boundary.

Single Markdown/HTML files discover referenced local resources before staging.
Only regular, non-symlink files below the selected parent are copied. Their
paths and digests participate in the snapshot digest; the primary file digest
remains the adapter revision. Local and remote fetchers share the same private
commit path, so origin type never bypasses atomic import or capacity policy.

Refresh uses a separate staging path that retains the existing Source identity.
It verifies the complete replacement container, reports an unchanged digest
without creating a Snapshot, and exposes only an immutable candidate for the
adapter/anchor validation phase. Failed candidates are discarded; the database
becomes current only in the later refresh transaction.

Local import creates a read-only security-scoped bookmark while the user-picked
URL is authorized. Refresh resolves it with security scope, renews stale data,
and balances every successful access with `stopAccessingSecurityScopedResource`.
Missing legacy authorization is surfaced to the AppModel for native re-selection
of the exact original path.

The actor serializes imports and managed-source removal. It rejects symlinks
during directory ingestion, includes package descendants in tree identity, and
uses an injectable capacity policy so large-import confirmation, reserve-space,
and dedup charging remain deterministic under test.

Removal sends only exclusively owned content-addressed containers to Trash,
keeps shared bytes, and never deletes the selected original. A failed metadata
commit attempts to restore already moved containers. The metadata transaction
also clears Source-bound reader state and invalidates affected Agent sessions;
the returned durable generations synchronize the in-memory runtime before its
revision barrier is released.

If a database record points to missing or corrupted managed bytes, a reimport
stages and verifies a fresh copy. The complete content container, including
referenced resources, is replaced as one same-volume unit, preserving the
immutable path used by existing snapshots.

Removal also reclaims rebuildable EPUB extraction directories keyed by the
Source's Snapshot IDs. Startup reconciles the EPUB derived namespace against
active database Snapshots, reclaiming any late extraction that raced with
Source removal. Durable original and managed-source Trash semantics stay
separate from this cache cleanup.
