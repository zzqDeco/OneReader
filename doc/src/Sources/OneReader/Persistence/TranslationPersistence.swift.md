# Translation cache

`TranslationPersistence.swift` owns additive DB v13 and Agent runtime schema 6. Cache records are derived, versioned, and separated by source/snapshot/paragraph, original digest, source/target language, Provider destination/model/revision and prompt/schema version. Reads revalidate the payload identity. Writes only occur inside the existing Agent generation/manifest/provider-bound finalization transaction. Deletion is narrow and does not change sources, annotations, progress or historical audits.
