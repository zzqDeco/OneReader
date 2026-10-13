import Foundation

struct CapturePreparedResult: Sendable {
    let imported: ManagedImportResult
    let plan: AdapterPlan
}

/// One host-owned import path; the extension never constructs this service.
actor CaptureCoordinator {
    let database: LibraryDatabase
    let staging: CaptureStagingStore
    private let library: ManagedLibrary
    private let remoteImporter: RemoteSourceImporter
    private let adapters: AdapterCoordinator
    private let sharedStaging: CaptureStagingStore?

    init(
        database: LibraryDatabase,
        library: ManagedLibrary,
        remoteImporter: RemoteSourceImporter,
        adapters: AdapterCoordinator,
        staging: CaptureStagingStore? = nil,
        sharedStaging: CaptureStagingStore? = nil
    ) {
        self.database = database
        self.library = library
        self.remoteImporter = remoteImporter
        self.adapters = adapters
        self.sharedStaging = sharedStaging
        self.staging = staging ?? CaptureStagingStore(
            rootURL: database.layout.rootURL.appendingPathComponent("Capture", isDirectory: true),
            maximumBytes: Int64.max, allowsDirectories: true
        )
    }

    @discardableResult
    func recover() throws -> Int {
        try staging.prepare()
        try database.recoverCaptureJobs()
        var failures = 0
        for id in try staging.receiptIDs() {
            do {
                let receipt = try staging.receipt(id: id)
                try database.receiveCapture(receipt)
                if try database.captureJob(receipt.id)?.phase == .ready {
                    try? staging.acknowledge(receipt)
                }
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Valid receipts continue even if a different attachment is corrupt.
    func receiveSharedHandoffs() throws -> Int {
        guard let sharedStaging else { return 0 }
        try sharedStaging.prepare()
        let directories = try FileManager.default.contentsOfDirectory(
            at: sharedStaging.rootURL.appendingPathComponent("ready"), includingPropertiesForKeys: nil
        )
        var failures = 0
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            do {
                let receipt = try sharedStaging.receipt(id: directory.lastPathComponent)
                if let existing = try database.captureJob(receipt.id), existing.phase == .ready {
                    guard existing.receipt.describesSameContent(as: receipt) else { throw CaptureError.conflictingReceipt }
                    try sharedStaging.acknowledge(receipt)
                    continue
                }
                try staging.adopt(receipt, from: sharedStaging)
                try database.receiveCapture(receipt)
                try sharedStaging.acknowledge(receipt)
            } catch { failures += 1 }
        }
        try publishDestinations()
        return failures
    }

    func publishDestinations() throws {
        try sharedStaging?.saveDestinations(
            database.fetchSpaces().filter { $0.organizationState != .archived }.map {
                CaptureSpaceDestination(id: $0.id, title: $0.title)
            }
        )
    }

    @discardableResult
    func receive(_ request: ReaderImportRequest, targetSpaceID: String? = nil, allowLargeImport: Bool = false) async throws -> CaptureReceipt {
        let receipt: CaptureReceipt
        switch request {
        case .local(let url):
            receipt = try await library.receiveLocalCapture(
                at: url, store: staging, targetSpaceID: targetSpaceID, allowLargeImport: allowLargeImport
            )
        case .remote(let url):
            receipt = try staging.receiveURL(url, targetSpaceID: targetSpaceID)
        }
        try database.receiveCapture(receipt, allowLargeImport: allowLargeImport)
        return receipt
    }

    func process(
        _ id: String, onChange: @Sendable () async -> Void = {}
    ) async -> CapturePreparedResult? {
        let context: CaptureImportContext
        do {
            guard let claim = try database.claimCapture(id) else { return nil }
            context = claim
        } catch { return nil }
        await onChange()
        do {
            try Task.checkCancellation()
            guard let job = try database.captureJob(id) else { throw CaptureError.invalidReceipt }
            let result: ManagedImportResult
            if let existing = try await library.existingCaptureImport(context) {
                result = existing
            } else {
                switch job.receipt.source {
                case .local:
                    guard let url = try staging.payloadURL(for: job.receipt) else { throw CaptureError.missingPayload }
                    result = try await library.importLocalSource(
                        at: url, intoSpaceID: job.receipt.targetSpaceID,
                        allowLargeImport: job.allowLargeImport, capture: context
                    )
                case .remote(let url):
                    result = try await remoteImporter.importSource(
                        from: url, intoSpaceID: job.receipt.targetSpaceID,
                        allowLargeImport: job.allowLargeImport, capture: context
                    )
                }
            }
            await onChange()
            try database.validateCaptureClaim(context)
            try Task.checkCancellation()
            let plan = try await adapters.prepare(sourceID: result.source.id, snapshotID: result.snapshot.id)
            try Task.checkCancellation()
            try database.finishCapture(context, phase: .ready)
            try? staging.acknowledge(job.receipt)
            try? publishDestinations()
            return CapturePreparedResult(imported: result, plan: plan)
        } catch is CancellationError {
            try? database.finishCapture(context, phase: .waitingForImport)
        } catch let error as URLError {
            let message = error.code == .notConnectedToInternet
                ? "链接已保存，当前无网络；联网后点“继续导入”。"
                : "链接已保存，网络取回未完成；检查连接后重试。"
            try? database.finishCapture(context, phase: .waitingForImport, error: message)
        } catch let error as LibraryStorageError {
            if case .largeImportRequiresConfirmation(let bytes) = error {
                try? database.finishCapture(
                    context, phase: .failed,
                    error: CaptureError.largeImportRequiresConfirmation(bytes).localizedDescription,
                    needsConfirmation: true
                )
            } else {
                try? database.finishCapture(context, phase: .failed, error: Self.safeMessage(for: error))
            }
        } catch {
            try? database.finishCapture(context, phase: .failed, error: Self.safeMessage(for: error))
        }
        return nil
    }

    static func safeMessage(for error: any Error) -> String {
        if let error = error as? CaptureError { return error.localizedDescription }
        if let error = error as? LibraryStorageError {
            switch error {
            case .insufficientFreeSpace: return CaptureError.insufficientCapacity.localizedDescription
            case .missingSpace: return "目标阅读空间已不存在。请重新收集到待整理，或选择其他空间。"
            case .symbolicLinkNotAllowed, .pathEscapesLibrary, .referencedResourceOutsideSource:
                return CaptureError.unsafeFile.localizedDescription
            default: return "无法读取托管副本；请检查原文件是否完整，再重试。"
            }
        }
        if let error = error as? RemoteSourceError {
            switch error {
            case .httpStatus(let status): return "远程来源返回 HTTP \(status)。链接仍保留，可稍后重试。"
            case .payloadTooLarge: return "远程内容超过下载上限，请下载文件后从本地导入。"
            case .unsafeHost, .redirectRejected: return "为保护本机和私网，已拒绝此地址或重定向；请使用公开 HTTPS 地址。"
            default: return "此链接暂时无法导入；请检查公开访问权限和内容格式。"
            }
        }
        return "导入未完成。内容仍保留，请检查文件或网络后重试。"
    }
}
