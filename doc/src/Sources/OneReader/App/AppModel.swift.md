# `Sources/OneReader/App/AppModel.swift`

Owns main-actor application orchestration:

- an empty first-launch Library and active imported reading graph;
- goal-specific reading-plan projection;
- selected unit and presentation;
- lazy repository/PDF loading;
- stale-task suppression;
- Library initialization and surfaced migration/storage failures;
- transitional progress loading while the native workspace slice moves all
  active progress into GRDB.

The app creates no demo Source and performs no background example-network call.
Source drivers and storage remain injected so deterministic behavior can be
tested independently. Library initialization runs off the main actor; if it
fails, current `progress-v2.json` may still load, but saving stays disabled
unless that load succeeds. PDF import does not bypass managed storage in a
degraded state.
