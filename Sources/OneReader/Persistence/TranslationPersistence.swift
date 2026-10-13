import Foundation
import GRDB

extension LibraryDatabase {
    static func registerTranslationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13-bilingual-translation-cache") { db in
            try db.execute(sql: """
                CREATE TABLE translation_cache (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    segment_id TEXT NOT NULL,
                    target_language TEXT NOT NULL,
                    provider_revision TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX translation_cache_source ON translation_cache(source_id, snapshot_id);
                UPDATE library_metadata SET value = '13' WHERE key = 'database_schema';
                UPDATE library_metadata SET value = '6' WHERE key = 'agent_runtime_schema';
                """)
        }
    }

    func cachedTranslation(segment: TranslationSegment, settings: TranslationSettings) throws -> CachedTranslation? {
        let key = try segment.cacheKey(settings: settings)
        return try pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload_json FROM translation_cache WHERE cache_key = ?", arguments: [key]) else { return nil }
            let value = try JSONDecoder.translation.decode(CachedTranslation.self, from: data)
            guard value.schemaVersion == TranslationSettings.schemaVersion,
                  value.promptVersion == TranslationSettings.promptVersion,
                  value.key == key, value.segment.id == segment.id,
                  value.segment.originalDigest == segment.originalDigest,
                  value.segment.originalText == segment.originalText,
                  value.segment.locator == segment.locator, value.settings == settings,
                  !value.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
    }

    func deleteTranslations(segments: [TranslationSegment], settings: TranslationSettings) throws {
        let keys = try segments.map { try $0.cacheKey(settings: settings) }
        try pool.write { db in
            for key in keys {
                try db.execute(sql: "DELETE FROM translation_cache WHERE cache_key = ?", arguments: [key])
            }
        }
    }

    func unfinishedTranslationSegmentIDs(spaceID: String, settings: TranslationSettings) throws -> Set<String> {
        try pool.read { db in
            let payloads = try Data.fetchAll(db, sql: """
                SELECT request_json FROM agent_runs
                WHERE space_id = ? AND task = 'translateFragments'
                  AND state IN ('failed', 'cancelled', 'interrupted')
                ORDER BY created_at DESC LIMIT 100
                """, arguments: [spaceID])
            return try payloads.reduce(into: Set<String>()) { result, payload in
                let request = try JSONDecoder.translation.decode(AgentRunRequest.self, from: payload)
                if request.translation?.settings == settings {
                    result.formUnion(request.translation?.segments.map(\.id) ?? [])
                }
            }
        }
    }

    /// Called only from Agent finalization, within the same generation/manifest/provider CAS transaction.
    static func commitTranslations(_ values: [CachedTranslation], db: Database,
                                   manifest: [String: String]) throws {
        for value in values {
            guard manifest[value.segment.locator.sourceID] == value.segment.locator.snapshotID,
                  value.key == (try value.segment.cacheKey(settings: value.settings)) else {
                throw ReadingAgentError.validationRejected("translation-cache-contract")
            }
            try db.execute(sql: """
                INSERT INTO translation_cache
                    (cache_key, source_id, snapshot_id, segment_id, target_language, provider_revision, payload_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cache_key) DO UPDATE SET payload_json = excluded.payload_json, created_at = excluded.created_at
                """, arguments: [value.key, value.segment.locator.sourceID,
                    value.segment.locator.snapshotID, value.segment.id,
                    value.settings.targetLanguage.rawValue, value.settings.providerRevisionIdentity,
                    try JSONEncoder.translation.encode(value), value.generatedAt])
        }
    }
}

extension JSONEncoder {
    static var translation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
extension JSONDecoder {
    static var translation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
