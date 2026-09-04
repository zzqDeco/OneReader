# `Sources/OneReader/Domain/ReaderWorkspaceModels.swift`

Owns reader-specific value types that do not belong to source-format identity:

- annotation kind and anchor state;
- source position, per-unit state, frozen-plan step, and reading history;
- presentation surface/document and current text selection;
- reader theme, typography, line width, line spacing, and PDF scale.

Preferences use an explicit defaults key and Codable schema. Quick Look
capability limits are enforced before a structured highlight is persisted.

`ReadingPositionCaptureRequest` names one window presentation target plus the
expected Source and Snapshot. Its main-actor claim is exclusive, and completion
must present the same target identity, so competing mounted readers cannot race
an asynchronous WebKit result into the shared model.
