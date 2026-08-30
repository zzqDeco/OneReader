# `Sources/OneReader/Persistence/ManagedLibrary.swift`

Owns local file/directory inspection, streaming SHA-256 and tree digests,
staging-copy verification, content-addressed storage, digest deduplication,
free-space enforcement, and the source/snapshot/Space commit boundary.

Single Markdown/HTML files discover referenced local resources before staging.
Only regular, non-symlink files below the selected parent are copied. Their
paths and digests participate in the snapshot digest; the primary file digest
remains the adapter revision. Local and remote fetchers share the same private
commit path, so origin type never bypasses atomic import or capacity policy.

The actor serializes imports and managed-source removal. It rejects symlinks
during directory ingestion, includes package descendants in tree identity, and
uses an injectable capacity policy so large-import confirmation, reserve-space,
and dedup charging remain deterministic under test.

Removal sends only exclusively owned content-addressed containers to Trash,
keeps shared bytes, and never deletes the selected original. A failed metadata
commit attempts to restore already moved containers.

If a database record points to missing or corrupted managed bytes, a reimport
stages and verifies a fresh copy. The complete content container, including
referenced resources, is replaced as one same-volume unit, preserving the
immutable path used by existing snapshots.

Removal also reclaims rebuildable EPUB extraction directories keyed by the
Source's Snapshot IDs. Startup reconciles the EPUB derived namespace against
active database Snapshots, reclaiming any late extraction that raced with
Source removal. Durable original and managed-source Trash semantics stay
separate from this cache cleanup.
