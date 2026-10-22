# `Sources/OneReader/Persistence/ReaderPersistence.swift`

Extends `LibraryDatabase` with annotation, progress, history, graph, plan, and
Provider-profile operations used by the native reader.

Writes validate Space membership and Locator Source/Snapshot identity before
commit. Source-position fractions must be finite and within 0...1, and their
display labels are bounded before encoding. Annotation queries for a Space
include annotations created on any Source currently attached to that Space in
`space_sources` so Inbox annotations remain visible after Space organization.
Annotation fetch order is stable,
history is bounded, progress is one
versioned payload per Space (including optional per-Source `SpaceSourceRole`
weights), and graph/plan reads never infer a newer Snapshot
than the one stored in their contracts. Source removal resets route-level
progress rather than leaving units or frozen plan steps bound to an invalidated
graph.
