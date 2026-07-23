# `Sources/OneReader/Domain/Models.swift`

Owns Codable and Sendable domain contracts shared by source drivers, the
semantic mapper, planner, persistence, and UI.

Invariants:

- snapshots are immutable and revision-bound;
- locators include the source revision;
- reading units contain source evidence;
- reading plans refer to exactly one graph version;
- progress schema versions are explicit.

