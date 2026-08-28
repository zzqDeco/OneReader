# `Sources/OneReader/Persistence/ManagedLibrary.swift`

Owns local file/directory inspection, streaming SHA-256 and tree digests,
staging-copy verification, content-addressed storage, digest deduplication,
free-space enforcement, and the source/snapshot/Space commit boundary.

The actor serializes imports and managed-source removal. It rejects symlinks
during directory ingestion, includes package descendants in tree identity, and
uses an injectable capacity policy so large-import confirmation, reserve-space,
and dedup charging remain deterministic under test.

Removal sends only exclusively owned content-addressed containers to Trash,
keeps shared bytes, and never deletes the selected original. A failed metadata
commit attempts to restore already moved containers.

If a database record points to missing or corrupted managed bytes, a reimport
stages and verifies a fresh copy. Missing payloads are restored by rename and
corrupted payloads by same-volume replacement, preserving the immutable path
used by existing snapshots.
