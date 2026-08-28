# `Sources/OneReader/UI/WorkspaceView.swift`

Owns the native macOS window composition:

- source and unit sidebar;
- central reading surface;
- route inspector;
- toolbar import and presentation actions;
- compact-window inspector/sidebar behavior.

The view delegates PDF rendering to PDFKit and state decisions to `AppModel`.

