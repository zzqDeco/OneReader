# OneReader Plan Index

`plan/` stores active implementation plans and concise records for recently
delivered work. Stable behavior belongs in [doc/](../doc/README.md).

## Status definitions

| Status | Meaning |
| --- | --- |
| Active | Still being designed, implemented, or used as a live decision source |
| Delivered | Implemented and verified; retained for short-term review context |
| Absorbed | Stable behavior is fully owned by `doc/` and the plan can be retired |
| Superseded | Replaced by a newer product or technical plan; not current direction |
| Retire Candidate | Delivered history that can be removed after the retention window |

## Plans

| Document | Purpose | Status |
| --- | --- | --- |
| [Apple multiplatform reader](apple-multiplatform-v1.plan.md) | Shared macOS, iPhone, and iPad app, adaptive native UI, and app icon | Active |
| [All-in-One Reader v1](all-in-one-reader-v1.plan.md) | Umbrella delivery plan for OneReader v0.2.0 | Delivered |
| [Library core v2](library-core-v2.plan.md) | Managed sources, snapshots, GRDB, migration, and empty Library | Delivered |
| [Source adapters v2](source-adapters-v2.plan.md) | Capability protocols, deterministic adapters, search, and presentations | Delivered |
| [Reading Agent runtime](reading-agent-runtime.plan.md) | Single-agent loop, provider boundary, validation, audit, and recovery | Delivered |
| [Native reader workspace](native-reader-workspace.plan.md) | Library-first native reading, annotations, history, routes, and accessibility | Delivered |
| [macOS 26 release](macos26-release.plan.md) | Unified validation, Sandbox packaging, CI, and release artifacts | Delivered |
| [Native reading-space MVP](native-reading-space-mvp.plan.md) | Historical GitHub/PDF vertical slice replaced by v0.2 | Superseded |

## Maintenance rules

- Add or update a narrow plan before non-trivial implementation.
- Keep the index synchronized in the same change.
- Move stable contracts into `doc/` when a plan is delivered.
- Keep ephemeral screenshots and local source material under `.onereader/`.
- Do not preserve long architecture explanations in both `plan/` and `doc/`.
