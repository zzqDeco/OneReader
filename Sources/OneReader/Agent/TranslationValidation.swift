import Foundation

extension TranslationDraft {
    func validated(for request: TranslationRequest, database: LibraryDatabase,
                   manifest: [String: String]) throws -> [CachedTranslation] {
        try request.validateShape()
        guard schemaVersion == TranslationSettings.schemaVersion,
              segments.map(\.id) == request.segments.map(\.id),
              segments.map(\.originalDigest) == request.segments.map(\.originalDigest) else {
            throw ReadingAgentError.validationRejected("translation-segment-order-or-digest")
        }
        return try zip(request.segments, segments).map { source, draft in
            guard manifest[source.locator.sourceID] == source.locator.snapshotID,
                  try database.hasObservation(for: source.locator, containing: source.originalText),
                  !draft.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  draft.translatedText.utf16.count <= min(16_000, max(2_000, source.originalText.utf16.count * 6)) else {
                throw ReadingAgentError.validationRejected("translation-not-grounded-or-bounded")
            }
            let translated = try source.restoringProtectedSpans(in: draft.translatedText)
            return CachedTranslation(key: try source.cacheKey(settings: request.settings),
                schemaVersion: schemaVersion, promptVersion: request.promptVersion,
                segment: source, settings: request.settings, translatedText: translated, generatedAt: .now)
        }
    }
}
