# `Sources/OneReader/Persistence/ReaderPersistence.swift`

Extends `LibraryDatabase` with annotation, progress, history, graph, plan, and
Provider-profile operations used by the native reader.

Writes validate Space membership and Locator Source/Snapshot identity before
commit. Annotation fetch order is stable, history is bounded, progress is one
versioned payload per Space, and graph/plan reads never infer a newer Snapshot
than the one stored in their contracts. Source removal resets route-level
progress rather than leaving units or frozen plan steps bound to an invalidated
graph.
