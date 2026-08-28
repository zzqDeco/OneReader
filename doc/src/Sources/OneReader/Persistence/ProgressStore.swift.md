# `Sources/OneReader/Persistence/ProgressStore.swift`

Owns the temporary JSON persistence used by the legacy vertical-slice reader
until progress moves fully into `Library.sqlite`.

New state is written to `progress-v2.json`. The distinct filename is a safety
boundary: `LibraryDatabase` may archive `progress-v1.json` as unbound legacy
input, but it must never classify current output as that legacy format.
