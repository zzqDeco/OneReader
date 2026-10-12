# `Sources/OneReader/Adapters/TextAdapters.swift`

Owns Markdown/text/code probes, native presentation, navigation lists, reads,
search, and quote-based relocation. Markdown AST headings remain an outline.

Host indexing reads permitted UTF-8 once, emits overlapping 64K-grapheme chunks
serially, and carries absolute UTF-16/line ranges. `indexTextRange=utf16` opts into
exact indexed-range reads without reinterpreting pre-existing outline or viewport
locators (`positionKind=textViewport` on AppKit and UIKit). Reads reject
out-of-bounds or split-grapheme ranges. CRLF/CR/LF are
handled as source line breaks, preserving original content bytes.

Cross-revision quote resolution ranks prefix/suffix context before original
UTF-16 proximity; ambiguous matches orphan. Resolved indexed ranges receive new
coordinates and keep the historical locator immutable. Every chunk remains
bound to the same Source/Snapshot/path and is checked for cancellation.
