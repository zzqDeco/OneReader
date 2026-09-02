# OneReader Documentation

`doc/` contains the current engineering truth for OneReader. Historical
implementation sequencing belongs in `plan/`.

## Start here

| Document | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Runtime layers, dependency direction, and progressive materialization |
| [Apple platforms](apple-platforms.md) | Shared target model, native shells, import/storage permissions, and multiplatform validation |
| [Interfaces](interfaces.md) | Source, snapshot, locator, observation, unit, graph, plan, and progress contracts |
| [Source adapters](source-adapters.md) | Deterministic format routing, snapshots, presentation, search, and safety |
| [Reading Agent runtime](reading-agent-runtime.md) | Single-agent lifecycle, providers, tools, budgets, validation, and recovery |
| [Reader workspace](reader-workspace.md) | Library-first native workspace, reading surfaces, search, annotations, and adaptive layout |
| [Acceptance](acceptance.md) | Automated and native manual acceptance matrix |
| [Branching](branching.md) | Branch roles, pull-request flow, and promotion rules |
| [GitHub Actions](github-actions.md) | Hosted CI and release behavior |
| [Design system](../design-system/onereader/MASTER.md) | Native visual language and interaction rules |
| [Source notes](src/README.md) | Responsibilities of important source files |

## Documentation rules

- Keep current behavior and stable contracts in `doc/`.
- Keep implementation intent and branch-local decisions in `plan/`.
- Keep short source ownership notes in `doc/src/`.
- Update indexes when adding, moving, or retiring documents.
- Do not commit downloaded demonstration PDFs or repository content.
- Run `python3 scripts/check-doc-index.py` and `git diff --check` for docs-only
  changes.

## Related files

- [README](../README.md): product entry point and local commands.
- [AGENTS.md](../AGENTS.md): coding-agent and review rules.
- [Plan index](../plan/README.md): active and recently delivered plans.
