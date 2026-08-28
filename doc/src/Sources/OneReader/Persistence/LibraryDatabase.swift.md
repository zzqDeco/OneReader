# `Sources/OneReader/Persistence/LibraryDatabase.swift`

Owns the GRDB `DatabasePool`, ordered migrations, WAL/foreign-key setup,
transactional source/snapshot/Space commits, schema metadata, and legacy
progress migration manifest. It also computes shared-content-aware removal
plans and commits Source removal with Space detachment in one transaction.

It records Provider Keychain references but never API keys. A legacy progress
file is moved only after database migration succeeds and is explicitly marked
as not bound to new objects.
