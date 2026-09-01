# `Sources/OneReader/UI/NativeMarkdownRenderer.swift`

Converts the pinned `swift-markdown` AST into a selectable
`NSAttributedString` for native reading. It handles headings, paragraphs,
emphasis, strong text, strike-through, inline/code blocks, lists, quotes,
thematic breaks, and tables.

Raw HTML is omitted. Images become alt-text placeholders and no image URL is
fetched. Only explicit HTTP(S) destinations receive link attributes. The
surrounding `NSTextView` coordinator derives quote context, fingerprint, and
source ranges for stable highlight Locators.
