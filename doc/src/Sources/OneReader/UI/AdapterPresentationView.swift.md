# `Sources/OneReader/UI/AdapterPresentationView.swift`

Owns presentation-surface registration and native bridges for PDFKit, selectable
Markdown/text/code, sanitized WebKit, and Quick Look.

WebKit is non-persistent and has JavaScript disabled. Managed resources are
served through a read-only custom scheme rooted at one snapshot directory;
automatic and cross-scheme navigation is cancelled. A user-activated HTTP(S)
link is the only path to the default browser.

The presentation descriptor makes Quick Look limitations machine-readable so
the workspace does not expose unsupported search or structured highlight UI.
