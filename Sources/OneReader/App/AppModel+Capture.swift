import Foundation

extension AppModel {
    var visibleCaptureJobs: [CaptureJob] {
        captureJobs.filter { job in
            let matchesText = librarySearchText.isEmpty
                || job.receipt.displayName.localizedStandardContains(librarySearchText)
            guard matchesText else { return false }
            if selectedCollection == .processing { return true }
            guard selectedCollection == .inbox || selectedCollection == .allSpaces else { return false }
            if job.phase != .ready { return true }
            return job.spaceID.flatMap { id in spaces.first { $0.id == id } }?.organizationState == .inbox
        }
    }

    func captureURLs(_ urls: [URL], intoSpaceID: String? = nil, allowLargeImport: Bool = false) {
        guard let captureCoordinator else {
            if !isBootstrapComplete {
                pendingExternalCaptureURLs.append(contentsOf: urls)
                for url in urls where url.isFileURL && url.startAccessingSecurityScopedResource() {
                    pendingCaptureScopedURLs.append(url)
                }
                return
            }
            notice = AppNotice(title: "资料库尚未就绪", message: "请稍后重新收集。")
            return
        }
        let accepted = Array(urls.prefix(CaptureStagingStore.maximumBatchCount))
        isReceivingCaptures += 1
        Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for url in accepted {
                defer { releaseCaptureScope(url) }
                do {
                    let request: ReaderImportRequest = url.isFileURL ? .local(url) : .remote(url)
                    try await captureCoordinator.receive(
                        request, targetSpaceID: intoSpaceID, allowLargeImport: allowLargeImport
                    )
                    reloadCaptureJobs()
                } catch let CaptureError.largeImportRequiresConfirmation(bytes) {
                    largeImportConfirmation = LargeImportConfirmation(
                        request: .local(url), destination: .inbox, byteCount: bytes
                    )
                } catch {
                    failures.append("\(url.isFileURL ? url.lastPathComponent : (url.host ?? "链接"))：\(CaptureCoordinator.safeMessage(for: error))")
                }
            }
            if urls.count > accepted.count {
                for url in urls.dropFirst(accepted.count) { releaseCaptureScope(url) }
                failures.append("超过每批 \(CaptureStagingStore.maximumBatchCount) 项的部分未接收，请分批添加。")
            }
            isReceivingCaptures -= 1
            if !failures.isEmpty {
                notice = AppNotice(title: "部分内容未接收", message: failures.joined(separator: "\n"))
            }
            selectedCollection = .inbox
            resumeCaptures()
        }
    }

    private func releaseCaptureScope(_ url: URL) {
        if let index = pendingCaptureScopedURLs.firstIndex(of: url) {
            pendingCaptureScopedURLs.remove(at: index).stopAccessingSecurityScopedResource()
        }
    }

    func reloadCaptureJobs() {
        guard let captureCoordinator else { return }
        do { captureJobs = try captureCoordinator.database.captureJobs() }
        catch { notice = AppNotice(title: "无法读取收件箱", message: CaptureCoordinator.safeMessage(for: error)) }
    }

    func resumeCaptures() {
        guard let captureCoordinator else { return }
        captureQueueNeedsRun = true
        guard captureQueueTask == nil else { return }
        captureQueueTask = Task { [weak self] in
            guard let self else { return }
            defer { captureQueueTask = nil }
            do {
                let failures = try await captureCoordinator.receiveSharedHandoffs()
                if failures > 0 {
                    notice = AppNotice(
                        title: "部分分享尚未接收",
                        message: "\(failures) 项分享暂时无法交接，原接收副本仍保留。请检查可用空间后重新打开 OneReader。"
                    )
                }
            } catch {
                notice = AppNotice(title: "分享交接未完成", message: CaptureCoordinator.safeMessage(for: error))
            }
            while captureQueueNeedsRun && !Task.isCancelled {
                captureQueueNeedsRun = false
                reloadCaptureJobs()
                let queued = captureJobs.filter { $0.phase == .received || $0.phase == .waitingForImport }
                for job in queued {
                    guard !Task.isCancelled else { return }
                    activeCaptureJobID = job.id
                    let processing = Task {
                        await captureCoordinator.process(job.id) {
                            await self.reloadCaptureJobs()
                        }
                    }
                    captureItemTask = processing
                    if let result = await processing.value { applyCaptureResult(result) }
                    activeCaptureJobID = nil
                    captureItemTask = nil
                    reloadCaptureJobs()
                }
            }
        }
    }

    func retryCapture(_ id: String, confirmLargeImport: Bool = false) {
        do {
            try captureCoordinator?.database.retryCapture(id, confirmLargeImport: confirmLargeImport)
            reloadCaptureJobs()
            resumeCaptures()
        } catch { notice = AppNotice(title: "无法重试", message: CaptureCoordinator.safeMessage(for: error)) }
    }

    func cancelCapture(_ id: String) {
        do {
            try captureCoordinator?.database.cancelCapture(id)
            if activeCaptureJobID == id { captureItemTask?.cancel() }
            reloadCaptureJobs()
        } catch { notice = AppNotice(title: "无法取消", message: CaptureCoordinator.safeMessage(for: error)) }
    }

    func setOrganization(_ state: SpaceOrganizationState, for ids: Set<String>) {
        do {
            try captureCoordinator?.database.setSpaceOrganization(state, spaceIDs: ids)
            reloadCaptureLibrary()
            Task { try? await captureCoordinator?.publishDestinations() }
        } catch { notice = AppNotice(title: "无法整理阅读空间", message: CaptureCoordinator.safeMessage(for: error)) }
    }

    func organizeCaptures(_ ids: Set<String>, intoSpaceID: String) {
        do {
            try captureCoordinator?.database.organizeCaptures(ids, intoSpaceID: intoSpaceID)
            reloadCaptureLibrary()
        } catch { notice = AppNotice(title: "无法整理材料", message: CaptureCoordinator.safeMessage(for: error)) }
    }
}
