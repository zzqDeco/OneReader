import Darwin
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Compiled into the host and the extension without linking the Library.
/// A directory is a receipt only after an atomic rename into the ready folder.
struct CaptureStagingStore: Sendable {
    static let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "OneReaderCaptureAppGroup") as? String
        ?? "group.io.github.zzqDeco.OneReader.capture"
    static let minimumFreeCapacity: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let largeImportThreshold: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumShareBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumBatchCount = 20
    static let maximumFileCount = 10_000
    let rootURL: URL
    var maximumBytes: Int64 = maximumShareBytes
    var allowsDirectories = false
    var isCancelled: @Sendable () -> Bool = { false }
    var capacity: @Sendable (URL) throws -> Int64 = { url in
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        return values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
    }

    static func shared() throws -> CaptureStagingStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw CaptureError.sharedContainerUnavailable }
        let store = CaptureStagingStore(
            rootURL: container.appendingPathComponent("Capture-v1", isDirectory: true)
        )
        do { try store.prepare() } catch { throw CaptureError.sharedContainerUnavailable }
        return store
    }

    func prepare() throws {
        for component in ["", "ready", "writing"] {
            let url = component.isEmpty ? rootURL : rootURL.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try rejectSymlinks(at: url)
        }
    }

    func receiveURL(
        _ url: URL,
        id: String = UUID().uuidString.lowercased(),
        targetSpaceID: String? = nil
    ) throws -> CaptureReceipt {
        try CaptureReceipt.validateRemoteURL(url)
        let receipt = CaptureReceipt(
            id: id, source: .remote(url), displayName: url.host ?? "网页",
            targetSpaceID: targetSpaceID
        )
        return try publish(receipt) { _ in }
    }

    /// Companions come only from the host's existing local-source inspector.
    /// The extension copies just the one attachment it was authorized to receive.
    func receiveFile(
        _ sourceURL: URL,
        id: String = UUID().uuidString.lowercased(),
        targetSpaceID: String? = nil,
        allowLargeImport: Bool = false,
        companions: [(url: URL, relativePath: String)] = [],
        suggestedFilename: String? = nil
    ) throws -> CaptureReceipt {
        guard sourceURL.isFileURL else { throw CaptureError.unsupportedFile }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw CaptureError.unsafeFile }
        let isDirectory = values.isDirectory == true
        let name = suggestedFilename ?? sourceURL.lastPathComponent
        guard (isDirectory && allowsDirectories)
                || (values.isRegularFile == true && Self.supportsFile(URL(fileURLWithPath: name))) else {
            throw CaptureError.unsupportedFile
        }
        let files = try fileTree(at: sourceURL)
        var size = try files.reduce(Int64(0)) { try $0 + fileSize($1) }
        for companion in companions {
            guard CaptureReceipt.isSafeRelativePath(companion.relativePath) else { throw CaptureError.unsafeFile }
            try rejectSymlinks(at: companion.url)
            size += try fileSize(companion.url)
        }
        guard size <= maximumBytes else { throw CaptureError.attachmentTooLarge(maximumBytes) }
        if size > Self.largeImportThreshold && !allowLargeImport {
            throw CaptureError.largeImportRequiresConfirmation(size)
        }
        guard CaptureReceipt.isSafeRelativePath(name), !name.contains("/") else { throw CaptureError.unsafeFile }
        let receipt = CaptureReceipt(
            id: id, source: .local(relativePath: "payload/\(name)", isDirectory: isDirectory),
            displayName: name, targetSpaceID: targetSpaceID, byteCount: size
        )
        return try publish(receipt) { directory in
            try ensureCapacity(for: size)
            let payload = directory.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try copyTree(sourceURL, to: payload.appendingPathComponent(name), maximum: size)
            for companion in companions {
                try copyFile(
                    companion.url,
                    to: payload.appendingPathComponent(companion.relativePath),
                    maximum: size
                )
            }
            try ensureCapacity(for: 0)
        }
    }

    func receiveText(
        _ data: Data, filename: String = "分享文本.txt",
        id: String = UUID().uuidString.lowercased(), targetSpaceID: String? = nil
    ) throws -> CaptureReceipt {
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CaptureError.attachmentTooLarge(4 * 1_024 * 1_024)
        }
        guard CaptureReceipt.isSafeRelativePath(filename), !filename.contains("/") else {
            throw CaptureError.unsafeFile
        }
        let receipt = CaptureReceipt(
            id: id, source: .local(relativePath: "payload/\(filename)", isDirectory: false),
            displayName: filename, targetSpaceID: targetSpaceID, byteCount: Int64(data.count)
        )
        return try publish(receipt) { directory in
            try ensureCapacity(for: Int64(data.count))
            let payload = directory.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            let url = payload.appendingPathComponent(filename)
            try data.write(to: url, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
        }
    }
    func receipts() throws -> [CaptureReceipt] {
        try receiptIDs().map(receipt(id:)).sorted { $0.createdAt < $1.createdAt }
    }

    func receiptIDs() throws -> [String] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("ready"), includingPropertiesForKeys: nil
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map(\.lastPathComponent).sorted()
    }

    func receipt(id: String) throws -> CaptureReceipt {
        let directory = try readyDirectory(id)
        let manifest = directory.appendingPathComponent("receipt.json")
        try rejectSymlinks(at: manifest)
        guard try fileSize(manifest) <= 64 * 1_024 else { throw CaptureError.invalidReceipt }
        let receipt = try JSONDecoder().decode(CaptureReceipt.self, from: Data(contentsOf: manifest))
        try receipt.validate()
        guard receipt.id == id else { throw CaptureError.invalidReceipt }
        try verifyPayload(for: receipt, in: directory)
        return receipt
    }

    func payloadURL(for receipt: CaptureReceipt) throws -> URL? {
        try receipt.validate()
        guard case .local(let path, _) = receipt.source else { return nil }
        let stored = try self.receipt(id: receipt.id)
        guard stored.describesSameContent(as: receipt) else { throw CaptureError.conflictingReceipt }
        let directory = try readyDirectory(receipt.id)
        let url = directory.appendingPathComponent(path)
        try rejectSymlinks(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.missingPayload }
        return url
    }

    /// Caller acknowledges the shared receipt only after the local database row.
    func adopt(_ receipt: CaptureReceipt, from incoming: CaptureStagingStore) throws {
        _ = try publish(receipt) { destination in
            if case .local = receipt.source {
                let sourcePayload = try incoming.readyDirectory(receipt.id).appendingPathComponent("payload")
                try ensureCapacity(for: receipt.byteCount)
                try copyTree(sourcePayload, to: destination.appendingPathComponent("payload"), maximum: receipt.byteCount)
                try ensureCapacity(for: 0)
            }
        }
    }

    func acknowledge(_ receipt: CaptureReceipt) throws {
        guard try self.receipt(id: receipt.id) == receipt else { throw CaptureError.conflictingReceipt }
        try FileManager.default.removeItem(at: readyDirectory(receipt.id))
    }

    func saveDestinations(_ destinations: [CaptureSpaceDestination]) throws {
        try prepare()
        let data = try JSONEncoder().encode(Array(destinations.prefix(500)))
        try data.write(to: rootURL.appendingPathComponent("destinations.json"), options: .atomic)
    }

    func destinations() throws -> [CaptureSpaceDestination] {
        let url = rootURL.appendingPathComponent("destinations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try rejectSymlinks(at: url)
        guard try fileSize(url) <= 256 * 1_024 else { throw CaptureError.invalidReceipt }
        return try JSONDecoder().decode([CaptureSpaceDestination].self, from: Data(contentsOf: url))
    }

    static func supportsFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["pdf", "epub", "md", "markdown", "mdown", "mkd", "txt", "text", "html", "htm", "xhtml"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .sourceCode) || type.conforms(to: .plainText)
    }

    private func publish(
        _ receipt: CaptureReceipt, writePayload: (URL) throws -> Void
    ) throws -> CaptureReceipt {
        try receipt.validate(requirePayloadDigest: false)
        try prepare()
        let final = try readyDirectory(receipt.id)
        if case .remote = receipt.source, FileManager.default.fileExists(atPath: final.path) {
            let prior = try self.receipt(id: receipt.id)
            guard prior.describesSameContent(as: receipt) else { throw CaptureError.conflictingReceipt }
            return prior
        }
        let writing = rootURL.appendingPathComponent("writing/\(receipt.id)-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: writing, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: writing) }
        try writePayload(writing)
        guard !isCancelled() else { throw CancellationError() }
        let verified: CaptureReceipt
        switch receipt.source {
        case .remote:
            verified = receipt
        case .local:
            guard receipt.version >= 2 || receipt.payloadDigest != nil else {
                throw CaptureError.unverifiedReceipt
            }
            let actual = try digestPayload(at: writing.appendingPathComponent("payload"))
            guard actual.byteCount == receipt.byteCount else { throw CaptureError.conflictingReceipt }
            if let expected = receipt.payloadDigest, expected != actual.digest {
                throw CaptureError.conflictingReceipt
            }
            verified = receipt.bindingPayload(to: actual.digest)
        }
        try verified.validate()
        // Local replay is compared only after its candidate bytes have been
        // staged and hashed; name/length equality is not content identity.
        if FileManager.default.fileExists(atPath: final.path) {
            let prior = try self.receipt(id: verified.id)
            guard prior.describesSameContent(as: verified) else { throw CaptureError.conflictingReceipt }
            return prior
        }
        let data = try JSONEncoder().encode(verified)
        let manifest = writing.appendingPathComponent("receipt.json")
        try data.write(to: manifest, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.synchronize()
        try handle.close()
        try syncDirectory(writing)
        do {
            try FileManager.default.moveItem(at: writing, to: final)
        } catch {
            if FileManager.default.fileExists(atPath: final.path) {
                let prior = try self.receipt(id: verified.id)
                guard prior.describesSameContent(as: verified) else { throw CaptureError.conflictingReceipt }
                return prior
            }
            throw error
        }
        try syncDirectory(final.deletingLastPathComponent())
        return verified
    }

    private func verifyPayload(for receipt: CaptureReceipt, in directory: URL) throws {
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        switch receipt.source {
        case .remote:
            guard !FileManager.default.fileExists(atPath: payload.path) else {
                throw CaptureError.conflictingReceipt
            }
        case .local:
            guard let expected = receipt.payloadDigest else { throw CaptureError.unverifiedReceipt }
            let actual = try digestPayload(at: payload)
            guard actual.digest == expected, actual.byteCount == receipt.byteCount else {
                throw CaptureError.conflictingReceipt
            }
        }
    }

    /// Stable, length-framed tree digest includes file names, entry kinds,
    /// empty directories and bytes. It is independent of mtimes/enumeration order.
    private func digestPayload(at root: URL) throws -> (digest: String, byteCount: Int64) {
        try rejectSymlinks(at: root)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CaptureError.missingPayload
        }
        var enumerationFailure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            errorHandler: { _, error in enumerationFailure = error; return false }
        ) else { throw CaptureError.missingPayload }
        var entries: [(path: String, url: URL)] = []
        for case let entry as URL in enumerator {
            try rejectSymlinks(at: entry)
            entries.append((try relativePath(entry, under: root), entry))
            guard entries.count <= Self.maximumFileCount else { throw CaptureError.tooManyFiles }
        }
        if let enumerationFailure { throw enumerationFailure }
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var hasher = SHA256()
        appendDigestField("OneReader.capture-payload.sha256.v1", to: &hasher)
        var totalBytes: Int64 = 0
        for entry in entries {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }
            let values = try entry.url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                appendDigestField("directory", to: &hasher)
                appendDigestField(entry.path, to: &hasher)
            } else if values.isRegularFile == true {
                appendDigestField("file", to: &hasher)
                appendDigestField(entry.path, to: &hasher)
                let descriptor = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw CaptureError.unsafeFile }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size >= 0 else { throw CaptureError.unsafeFile }
                let expectedSize = Int64(metadata.st_size)
                appendDigestField(String(expectedSize), to: &hasher)
                var fileBytes: Int64 = 0
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    guard !isCancelled() else { throw CancellationError() }
                    guard Int64(data.count) <= maximumBytes - totalBytes,
                          Int64(data.count) <= expectedSize - fileBytes else {
                        throw CaptureError.conflictingReceipt
                    }
                    hasher.update(data: data)
                    fileBytes += Int64(data.count)
                    totalBytes += Int64(data.count)
                }
                guard fileBytes == expectedSize else { throw CaptureError.conflictingReceipt }
            } else {
                throw CaptureError.unsafeFile
            }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), totalBytes)
    }

    private func appendDigestField(_ field: String, to hasher: inout SHA256) {
        let bytes = Data(field.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }

    private func readyDirectory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, id == id.lowercased() else { throw CaptureError.invalidReceipt }
        let directory = rootURL.appendingPathComponent("ready/\(id)", isDirectory: true)
        try rejectSymlinks(at: directory)
        return directory
    }

    private func fileTree(at url: URL) throws -> [URL] {
        try rejectSymlinks(at: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isRegularFile == true { return [url] }
        guard values.isDirectory == true else { throw CaptureError.unsafeFile }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in failure = error; return false }
        ) else { throw CaptureError.missingPayload }
        var files: [URL] = []
        for case let entry as URL in enumerator {
            try rejectSymlinks(at: entry)
            if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(entry)
                guard files.count <= Self.maximumFileCount else { throw CaptureError.tooManyFiles }
            }
        }
        if let failure { throw failure }
        return files
    }

    private func copyTree(_ source: URL, to destination: URL, maximum: Int64) throws {
        let files = try fileTree(at: source)
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if let directories = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for case let directory as URL in directories {
                    try rejectSymlinks(at: directory)
                    if try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        let relative = try relativePath(directory, under: source)
                        try FileManager.default.createDirectory(
                            at: destination.appendingPathComponent(relative), withIntermediateDirectories: true
                        )
                    }
                }
            }
            var total: Int64 = 0
            for file in files {
                let relative = try relativePath(file, under: source)
                total += try fileSize(file)
                guard total <= maximum else { throw CaptureError.unsafeFile }
                try copyFile(file, to: destination.appendingPathComponent(relative), maximum: maximum)
            }
        } else {
            try copyFile(source, to: destination, maximum: maximum)
        }
    }

    private func copyFile(_ source: URL, to destination: URL, maximum: Int64) throws {
        try rejectSymlinks(at: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CaptureError.unsafeFile }
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CaptureError.unsafeFile }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var written: Int64 = 0
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }
            written += Int64(data.count)
            guard written <= maximum else { throw CaptureError.unsafeFile }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func relativePath(_ url: URL, under root: URL) throws -> String {
        // FileManager enumerators may return /private/var while their input is
        // /var. Both have already passed symlink validation; canonicalize both
        // sides before deriving the child path, never drop an unchecked prefix.
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), components.count > rootComponents.count else {
            throw CaptureError.unsafeFile
        }
        let path = components.dropFirst(rootComponents.count).joined(separator: "/")
        guard CaptureReceipt.isSafeRelativePath(path) else { throw CaptureError.unsafeFile }
        return path
    }

    private func ensureCapacity(for bytes: Int64) throws {
        guard try capacity(rootURL) - bytes >= Self.minimumFreeCapacity else {
            throw CaptureError.insufficientCapacity
        }
    }

    private func rejectSymlinks(at url: URL) throws {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                // Apple's public temporary/container URLs can use these fixed
                // system aliases. User-controlled symlink ancestors remain denied.
                let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
                // Foundation intentionally canonicalizes /private/var back to
                // /var, so compare the actual link target, not resolved URL text.
                let actualTarget = target.hasPrefix("/") ? target : "/" + target
                guard systemAliases[candidate.path] == actualTarget else {
                    throw CaptureError.unsafeFile
                }
            }
            candidate.deleteLastPathComponent()
        }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CaptureError.unsafeFile }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CaptureError.unsafeFile }
    }
}
