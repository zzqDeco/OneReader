# `Sources/OneReader/UI/NativeMarkdownRenderer.swift`

Converts the pinned `swift-markdown` AST into a selectable
`NSAttributedString` for native reading. It handles headings, paragraphs,
emphasis, strong text, strike-through, inline/code blocks, lists, quotes,
thematic breaks, and tables.

Raw HTML is omitted. Remote image URLs are never fetched. Relative images are
resolved through `ReadOnlyContentResourceLoader` under the presentation's
Snapshot resource root, so path traversal, symlinks, unsupported media, and
oversized payloads fail closed to alt text. ImageIO metadata is checked before
decode: either dimension above 16,384 pixels or more than 64 Mi pixels is
rejected, and accepted images are downsampled to at most 4,096 pixels on their
long edge before becoming an attachment. A rendered attachment carries an
unavailable-map sentinel and cannot become a fabricated text Locator. Tables
render as readable pipe-delimited rows with preserved cell source mapping rather
than tabs. Only explicit HTTP(S) destinations receive link attributes. The
renderer carries source UTF-16 attributes on emitted leaf text. The surrounding
`NSTextView` coordinator maps ranges in both directions, derives source quote
context and fingerprints, distinguishes repeated heading/emphasis/list text,
and fails closed when synthetic rendering has no source mapping. Each mapping
starts from the AST leaf's source range; UTF-8 byte columns are converted to
UTF-16 offsets before escapes and HTML entities are aligned within that bounded
range. Inline-code backtick runs and fenced-code delimiter/language lines are
structurally excluded first; an ambiguous code boundary produces no map. Hidden
code syntax, link destinations, and omitted raw HTML therefore cannot capture an
equal visible string elsewhere in the document. Mapping attributes are committed
only when runs cover the entire rendered leaf. CommonMark code-span newline
normalization, indented fences, and indented blocks fail closed for the whole
leaf rather than returning a partial or syntax-anchored range. The renderer
marks such leaves with an unavailable-map sentinel; both mapping directions
reject any selection intersecting it, including left/right cross-leaf ranges.
