# OneReader Plan Index

`plan/` stores active implementation plans and concise records for recently
delivered work. Stable behavior belongs in [doc/](../doc/README.md).

## Status definitions

| Status | Meaning |
| --- | --- |
| Active | Still being designed, implemented, or used as a live decision source |
| Delivered | Implemented and verified; retained for short-term review context |
| Absorbed | Stable behavior is fully owned by `doc/` and the plan can be retired |

## Plans

| Document | Purpose | Status |
| --- | --- | --- |
| [Native reading-space MVP](native-reading-space-mvp.plan.md) | Deliver the first GitHub/PDF reading graph and native reader vertical slice | Delivered |

## Maintenance rules

- Add or update a narrow plan before non-trivial implementation.
- Keep the index synchronized in the same change.
- Move stable contracts into `doc/` when a plan is delivered.
- Keep ephemeral screenshots and local source material under `.onereader/`.
- Do not preserve long architecture explanations in both `plan/` and `doc/`.
