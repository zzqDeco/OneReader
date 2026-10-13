# Translation contracts

`TranslationModels.swift` owns the bounded `TranslationRequest`, original `SourceFragment`/Locator-bound segments, provider/language/version cache identity and model-only `TranslationDraft`. Translated offsets never become source offsets. Protected code/math/link spans must round-trip through opaque placeholders.

`TranslationSourceBuilder.swift` builds segments from Markdown AST, controlled HTML DOM or adapter-provided page/OCR text. Only locally derived, exact source observations are persisted for later validation. `TranslationValidation.swift` verifies the entire ordered ID/digest set before constructing host cache mutations. `TranslationPrompt.swift` includes only declared fragments; the single Agent exposes no tools or prior transcript for this task.

HTML selections resolve their actual inline DOM node to the nearest included ancestor block. Missing or ambiguous paths and non-unique text within that owner fail closed; repeated text in another paragraph is not a fallback.

`BilingualAnchorResolver` handles both restoration and follow-source scrolling within at most 12 loaded segments. Exact stable identity and original UTF-16 offsets precede rectangle, DOM-owner and line-range matches. Ranges are half-open, and ambiguous same-page/same-line candidates do not choose the first row. The resolver never constructs translated offsets or changes persisted locators.
