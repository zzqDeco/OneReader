import Foundation

enum TranslationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动（未确认）"
        case .simplifiedChinese: "简体中文"
        case .english: "英语"
        }
    }
}

enum BilingualLayout: String, CaseIterable, Identifiable, Sendable {
    case interleaved, original, translation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .interleaved: "对照"
        case .original: "原文"
        case .translation: "译文"
        }
    }
}

struct TranslationSettings: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    static let promptVersion = 1
    let sourceLanguage: TranslationLanguage
    let targetLanguage: TranslationLanguage
    let providerProfileID: String
    let providerDestinationIdentity: String
    let providerRevisionIdentity: String
    let modelID: String
    let providerName: String

    init(sourceLanguage: TranslationLanguage, targetLanguage: TranslationLanguage,
         profile: ProviderProfile) throws {
        guard targetLanguage != .automatic, sourceLanguage != targetLanguage else {
            throw TranslationError.invalidLanguages
        }
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        providerProfileID = profile.id
        providerDestinationIdentity = try ProviderPolicy.destinationIdentity(profile)
        providerRevisionIdentity = try ProviderPolicy.revisionIdentity(profile)
        modelID = profile.modelID
        providerName = profile.displayName
    }
}

struct TranslationProtectedSpan: Codable, Hashable, Sendable {
    let token: String
    let original: String
}

/// All offsets below name immutable ORIGINAL content. The translated string has no Locator.
struct TranslationSegment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let order: Int
    let fragment: SourceFragment
    let originalText: String
    let originalDigest: String
    let modelText: String
    let protectedSpans: [TranslationProtectedSpan]
    let isVerbatim: Bool

    var locator: Locator { fragment.locator }
    func cacheKey(settings: TranslationSettings) throws -> String {
        struct Key: Encodable {
            let schema: Int
            let prompt: Int
            let fragment: String
            let digest: String
            let settings: TranslationSettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AdapterUtilities.sha256(try encoder.encode(Key(
            schema: TranslationSettings.schemaVersion, prompt: TranslationSettings.promptVersion,
            fragment: id, digest: originalDigest, settings: settings
        )))
    }

    func restoringProtectedSpans(in translated: String) throws -> String {
        var text = translated
        for span in protectedSpans {
            guard text.components(separatedBy: span.token).count == 2 else {
                throw TranslationError.invalidOutput("protected-span")
            }
            text = text.replacingOccurrences(of: span.token, with: span.original)
        }
        guard !text.contains("⟦OR_KEEP_") else {
            throw TranslationError.invalidOutput("unknown-protected-span")
        }
        return text
    }
}

struct TranslationRequest: Codable, Hashable, Sendable {
    static let maximumSegments = 12
    static let maximumCharacters = 12_000
    static let maximumSegmentCharacters = 4_000
    let schemaVersion: Int
    let promptVersion: Int
    let settings: TranslationSettings
    let segments: [TranslationSegment]

    init(settings: TranslationSettings, segments: [TranslationSegment]) {
        schemaVersion = TranslationSettings.schemaVersion
        promptVersion = TranslationSettings.promptVersion
        self.settings = settings
        self.segments = segments
    }

    func validateShape() throws {
        guard schemaVersion == TranslationSettings.schemaVersion,
              promptVersion == TranslationSettings.promptVersion,
              !segments.isEmpty, segments.count <= Self.maximumSegments,
              Set(segments.map(\.id)).count == segments.count,
              Set(segments.map(\.order)).count == segments.count,
              segments.map(\.order) == segments.map(\.order).sorted(),
              segments.reduce(0, { $0 + $1.originalText.utf16.count }) <= Self.maximumCharacters,
              settings.targetLanguage != .automatic,
              settings.targetLanguage != settings.sourceLanguage else {
            throw TranslationError.invalidOutput("request-contract")
        }
        for segment in segments {
            guard !segment.isVerbatim, !segment.originalText.isEmpty,
                  segment.id == segment.fragment.id,
                  segment.originalText.utf16.count <= Self.maximumSegmentCharacters,
                  segment.originalDigest == AdapterUtilities.sha256(segment.originalText),
                  segment.fragment.sourceID == segment.locator.sourceID,
                  segment.locator.schemaVersion == Locator.currentSchemaVersion,
                  segment.locator.textQuote?.exact == segment.originalText,
                  try segment.restoringProtectedSpans(in: segment.modelText) == segment.originalText else {
                throw TranslationError.invalidOutput("segment-contract")
            }
        }
    }
}

/// Model may supply only ordered IDs, original digests and translations, never Locators or settings.
struct TranslationDraft: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let segments: [Segment]
    struct Segment: Codable, Hashable, Sendable {
        let id: String
        let originalDigest: String
        let translatedText: String
    }
}

struct CachedTranslation: Identifiable, Codable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let schemaVersion: Int
    let promptVersion: Int
    let segment: TranslationSegment
    let settings: TranslationSettings
    let translatedText: String
    let generatedAt: Date
}

enum TranslationError: LocalizedError, Equatable {
    case noText, selectionNotGrounded, invalidLanguages, invalidOutput(String)
    var errorDescription: String? {
        switch self {
        case .noText: "当前范围没有可翻译正文。扫描 PDF 或图片请先完成本地 OCR；原文仍可阅读。"
        case .selectionNotGrounded: "未能将选区唯一对应到原文，请重新选择较短的完整段落。"
        case .invalidLanguages: "请选择不同的源语言和目标语言。"
        case .invalidOutput: "译文未通过原文映射或结构校验，未写入缓存。"
        }
    }
}

enum BilingualProgressMapping {
    static func sourceLocator(_ locator: Locator, surface: PresentationSurface?) -> Locator {
        guard locator.payload["derivedText"] == "ocr" else { return locator }
        let removed: Set<String> = ["ocrRevisionID", "ocrSpanID", "ocrSchema", "derivedText",
            "pageTextStartUTF16", "pageTextEndUTF16", "startUTF16", "endUTF16", "indexTextRange"]
        return Locator(sourceID: locator.sourceID, snapshotID: locator.snapshotID,
            adapterID: surface == .pdfKit ? "onereader.pdf" : "onereader.image",
            payload: locator.payload.filter { !removed.contains($0.key) },
            structuralPath: locator.structuralPath, textQuote: nil, fingerprint: nil)
    }
}
