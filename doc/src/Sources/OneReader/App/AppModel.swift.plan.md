# `Sources/OneReader/App/AppModel.swift`

Owns main-actor application orchestration:

- active source snapshots and reading graph;
- goal-specific reading-plan projection;
- selected unit and presentation;
- lazy repository/PDF loading;
- stale-task suppression;
- progress loading and atomic persistence.

Source drivers and storage remain injected so deterministic behavior can be
tested independently.

