import Foundation

enum ProgressStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "阅读进度来自更高版本的数据格式（\(version)），当前版本不会覆盖它。"
        }
    }
}

actor ProgressStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> ReadingProgress {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        let progress = try decoder.decode(ReadingProgress.self, from: data)
        guard progress.schemaVersion == ReadingProgress.currentSchemaVersion else {
            throw ProgressStoreError.unsupportedSchema(progress.schemaVersion)
        }
        return progress
    }

    func save(_ progress: ReadingProgress) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(progress)
        try data.write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OneReader", isDirectory: true)
            .appendingPathComponent("progress-v1.json", isDirectory: false)
    }
}
