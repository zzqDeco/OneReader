# `Sources/OneReader/Persistence/ApplicationSupportLayout.swift`

Owns the canonical per-sandbox Application Support directories, path containment checks,
large-import threshold, and post-import free-space floor. `LibraryStoragePolicy`
wraps those production limits and the capacity probe so tests can exercise the
same decision path without multi-gigabyte fixtures.

Callers store only relative managed paths in the database. Converting a path
that escapes the OneReader root fails instead of silently normalizing it.
