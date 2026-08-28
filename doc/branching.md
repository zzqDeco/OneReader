# Branching and pull-request workflow

## Branch roles

- `main`: stable, releasable, and the only branch eligible for release tags.
- `dev`: integration branch for accepted topic work.
- `feature/*`: user-visible behavior.
- `fix/*`: defect repair.
- `docs/*`: documentation-only changes.
- `refactor/*`: internal structure without intended behavior change.
- `test/*`: verification harnesses.
- `ci/*`: GitHub Actions and packaging.
- `chore/*`: repository maintenance.
- `release/*`: short-lived stabilization when a direct `dev → main` promotion
  is not sufficient.

## Standard flow

1. Start from a clean and current `dev`.
2. Create one focused topic branch.
3. Add or update an implementation plan before non-trivial work.
4. Keep current-state documentation and source notes synchronized.
5. Run the local validation bundle.
6. Open a pull request into `dev`.
7. Merge only after current-head review and required CI are clean.
8. Promote `dev` into `main` through a separate pull request.
9. Create an annotated `vX.Y.Z` tag only on a commit reachable from `main`.

Direct routine pushes to `main` or `dev` are discouraged. Repository branch
protection should require pull requests and the `CI / Native validation`
check when a GitHub remote is configured.

## Commit format

Use Conventional Commits:

```text
feat(reader): add PDF comparison mode
fix(github): reject stale raw-content responses
docs(architecture): record snapshot invalidation
```

## Validation boundaries

Green CI proves deterministic build and tests. It does not prove native visual
acceptance, live GitHub reachability, PDF fidelity, signing, or notarization.
Those gates remain separately recorded.
