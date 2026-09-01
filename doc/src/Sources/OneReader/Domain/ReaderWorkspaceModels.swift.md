# `Sources/OneReader/Domain/ReaderWorkspaceModels.swift`

Owns reader-specific value types that do not belong to source-format identity:

- annotation kind and anchor state;
- source position, per-unit state, frozen-plan step, and reading history;
- presentation surface/document and current text selection;
- reader theme, typography, line width, line spacing, and PDF scale.

Preferences use an explicit defaults key and Codable schema. Quick Look
capability limits are enforced before a structured highlight is persisted.
