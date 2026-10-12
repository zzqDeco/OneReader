# `Sources/OneReader/Domain/ReaderWorkspaceModels.swift`

Owns reader-specific value types that do not belong to source-format identity:

- annotation kind and anchor state;
- source position, per-unit state, frozen-plan step, and reading history;
- presentation surface/document and current text selection;
- reader theme, typography, line width, line spacing, and PDF scale.

`PDFZoomRequest` carries an ephemeral command UUID and zoom-in, zoom-out, or
fit-width action. It is not persisted as reading progress or a global default;
the UIKit controller consumes a command once against the live native scale.
The reader binds each request to its presentation generation before forwarding
it, so changing documents cannot replay the previous document's last command.

Preferences use an explicit defaults key and Codable schema. Quick Look
capability limits are enforced before a structured highlight is persisted.

`ReadingPositionCaptureRequest` names one window presentation target plus the
expected Source and Snapshot. Its main-actor claim is exclusive, and completion
must present the same target identity, so competing mounted readers cannot race
an asynchronous WebKit result into the shared model.
