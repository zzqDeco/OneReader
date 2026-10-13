# Translation contracts

`TranslationModels.swift` owns the bounded `TranslationRequest`, original `SourceFragment`/Locator-bound segments, provider/language/version cache identity and model-only `TranslationDraft`. Translated offsets never become source offsets. Protected code/math/link spans must round-trip through opaque placeholders.

`TranslationSourceBuilder.swift` builds segments from Markdown AST, controlled HTML DOM or adapter-provided page/OCR text. Only locally derived, exact source observations are persisted for later validation. `TranslationValidation.swift` verifies the entire ordered ID/digest set before constructing host cache mutations. `TranslationPrompt.swift` includes only declared fragments; the single Agent exposes no tools or prior transcript for this task.
