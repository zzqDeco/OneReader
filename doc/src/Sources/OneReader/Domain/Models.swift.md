# `Sources/OneReader/Domain/Models.swift`

Owns Codable and Sendable core contracts shared by managed ingestion,
deterministic adapters, Agent validation, persistence, and the reader.

Invariants:

- snapshots are immutable and revision-bound;
- locators include Source, Snapshot, adapter, schema, structural/quote anchors,
  and a fingerprint;
- reading units contain source evidence;
- reading plans refer to exactly one graph version;
- `ReadingPositionUpdate` normalizes every presentation callback to a Locator,
  optional 0...1 fraction, document/text/page/DOM granularity, and short label;
- `SourcePosition` persists that metadata with optional fields so existing
  schema-v1 payloads remain decodable;
- models never contain a closed Repo/PDF product-mode enum.
