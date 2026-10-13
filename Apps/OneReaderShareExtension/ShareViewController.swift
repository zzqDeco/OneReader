import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var model: ShareCaptureModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let model = ShareCaptureModel(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        self.model = model
        let host = UIHostingController(rootView: ShareCaptureView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareRow: Identifiable {
    let id: Int
    let name: String
    var detail = "等待接收"
    var received = false
    var failed = false
    var loading = false
}

@MainActor
private final class ShareCaptureModel: ObservableObject {
    @Published var rows: [ShareRow]
    @Published var destinations: [CaptureSpaceDestination] = []
    @Published var targetSpaceID = ""
    @Published var running = false
    @Published var finished = false
    @Published var setupError: String?
    private let providers: [NSItemProvider]
    private let finish: () -> Void
    private let store: CaptureStagingStore?
    private var work: Task<Void, Never>?

    init(providers: [NSItemProvider], finish: @escaping () -> Void) {
        self.providers = providers
        self.finish = finish
        rows = providers.enumerated().map {
            ShareRow(id: $0.offset, name: $0.element.suggestedName ?? "附件 \($0.offset + 1)")
        }
        do {
            let store = try CaptureStagingStore.shared()
            self.store = store
            destinations = (try? store.destinations()) ?? []
            if providers.isEmpty { setupError = "没有可接收的附件，请在 Safari 或“文件”中重新分享。" }
        } catch {
            store = nil
            setupError = CaptureError.sharedContainerUnavailable.localizedDescription
        }
    }

    func receive() {
        guard !running, !finished, let store, setupError == nil else { return }
        running = true
        let target = targetSpaceID.isEmpty ? nil : targetSpaceID
        work = Task { [weak self] in
            guard let self else { return }
            let start = Date.now
            for index in providers.indices {
                guard !Task.isCancelled else { break }
                guard index < CaptureStagingStore.maximumBatchCount,
                      Date.now.timeIntervalSince(start) < 45 else {
                    rows[index].failed = true
                    rows[index].detail = "本次接收已达到数量或时间上限，请再次分享此项。"
                    continue
                }
                rows[index].loading = true
                rows[index].detail = "正在保存副本…"
                do {
                    _ = try await ShareAttachmentReceiver.receive(
                        providers[index], store: store, targetSpaceID: target
                    )
                    rows[index].received = true
                    rows[index].detail = "已接收，等待打开 OneReader 处理。"
                } catch is CancellationError {
                    rows[index].detail = "已取消，未确认接收。"
                    rows[index].failed = true
                } catch {
                    rows[index].detail = (error as? CaptureError)?.localizedDescription
                        ?? "未接收：附件加载失败或超时，请在原 App 中重试。"
                    rows[index].failed = true
                }
                rows[index].loading = false
            }
            running = false
            finished = true
        }
    }

    func close() {
        work?.cancel()
        finish()
    }
}

private struct ShareCaptureView: View {
    @ObservedObject var model: ShareCaptureModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("链接或文件先保存到收件箱。无需账号或模型服务；下载和阅读准备在打开 OneReader 后进行。")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("整理到", selection: $model.targetSpaceID) {
                        Text("待整理").tag("")
                        ForEach(model.destinations) { item in Text(item.title).tag(item.id) }
                    }
                    .disabled(model.running || model.finished)
                }
                Section("附件（\(model.rows.count)）") {
                    ForEach(model.rows) { row in
                        HStack(alignment: .top) {
                            if row.loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: row.received ? "checkmark.circle.fill" : (row.failed ? "exclamationmark.circle" : "doc"))
                                    .foregroundStyle(row.failed ? Color.red : Color.accentColor)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).font(.headline)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let error = model.setupError {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    Text("每次最多 20 项；单个文件不超过 512 MiB。支持 PDF、EPUB、图片、HTML、Markdown、文本和代码。图片仅接收，不代表已完成文字识别。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("已接收的项目会保留，关闭扩展不会删除；不支持的附件会逐项说明。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("收集到 OneReader")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.finished ? "完成" : "取消") { model.close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !model.finished {
                        Button("接收") { model.receive() }
                            .disabled(model.running || model.setupError != nil)
                    }
                }
            }
        }
    }
}

/// NSItemProvider callbacks run outside the main actor. Only a receipt crosses
/// back; provider temporary files are copied before the callback returns.
private enum ShareAttachmentReceiver {
    @MainActor
    static func receive(_ provider: NSItemProvider, store: CaptureStagingStore, targetSpaceID: String?) async throws -> CaptureReceipt {
        let operation = ShareLoadOperation()
        var boundedStore = store
        boundedStore.isCancelled = { operation.isCancelled }
        let receiptStore = boundedStore
        let identifier = UUID().uuidString.lowercased()
        let fileURLType = UTType.fileURL.identifier
        let urlType = UTType.url.identifier
        let fileType = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf)
                || type.conforms(to: .epub) || type.conforms(to: .html)
                || type.conforms(to: .text) || type.conforms(to: .sourceCode)
        }
        let suggestedName = provider.suggestedName
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.begin(continuation)
                if provider.hasItemConformingToTypeIdentifier(fileURLType) {
                    provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { value, error in
                        guard !operation.isCancelled else { return }
                        do {
                            if let error { throw error }
                            guard let url = value as? URL, url.isFileURL else { throw CaptureError.unsupportedFile }
                            let receipt = try receiptStore.receiveFile(url, id: identifier, targetSpaceID: targetSpaceID)
                            operation.finish(.success(receipt))
                        } catch { operation.finish(.failure(error)) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(urlType) {
                    provider.loadItem(forTypeIdentifier: urlType, options: nil) { value, error in
                        guard !operation.isCancelled else { return }
                        do {
                            if let error { throw error }
                            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                            guard let url else { throw CaptureError.invalidURL }
                            operation.finish(.success(try receiptStore.receiveURL(url, id: identifier, targetSpaceID: targetSpaceID)))
                        } catch { operation.finish(.failure(error)) }
                    }
                } else if let fileType,
                          UTType(fileType)?.conforms(to: .plainText) == true,
                          suggestedName == nil {
                    let progress = provider.loadDataRepresentation(forTypeIdentifier: fileType) { data, error in
                        guard !operation.isCancelled else { return }
                        do {
                            if let error { throw error }
                            guard let data else { throw CaptureError.unsupportedFile }
                            operation.finish(.success(try receiptStore.receiveText(
                                data, id: identifier, targetSpaceID: targetSpaceID
                            )))
                        } catch { operation.finish(.failure(error)) }
                    }
                    operation.setProgress(progress)
                } else if let fileType {
                    let preferredExtension = UTType(fileType)?.preferredFilenameExtension ?? "txt"
                    let safeName = suggestedName?.replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "\\", with: "_")
                    let base = safeName?.isEmpty == false ? String(safeName!.prefix(180)) : "分享附件"
                    let name = (base as NSString).pathExtension.isEmpty ? "\(base).\(preferredExtension)" : base
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: fileType) { url, error in
                        guard !operation.isCancelled else { return }
                        do {
                            if let error { throw error }
                            guard let url else { throw CaptureError.unsupportedFile }
                            let receipt = try receiptStore.receiveFile(
                                url, id: identifier, targetSpaceID: targetSpaceID, suggestedFilename: name
                            )
                            operation.finish(.success(receipt))
                        } catch { operation.finish(.failure(error)) }
                    }
                    operation.setProgress(progress)
                } else {
                    operation.finish(.failure(CaptureError.unsupportedFile))
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// One lock protects callback/timeout/cancellation ownership of the continuation.
private final class ShareLoadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureReceipt, any Error>?
    private var progress: Progress?
    private var completed = false
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }

    func begin(_ value: CheckedContinuation<CaptureReceipt, any Error>) {
        let shouldCancel = lock.withLock {
            if cancelled { return true }
            continuation = value
            return false
        }
        if shouldCancel { value.resume(throwing: CancellationError()); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in self?.cancel() }
    }

    func setProgress(_ value: Progress) {
        let shouldCancel = lock.withLock { progress = value; return cancelled }
        if shouldCancel { value.cancel() }
    }

    func finish(_ result: Result<CaptureReceipt, any Error>) {
        let value = lock.withLock { () -> CheckedContinuation<CaptureReceipt, any Error>? in
            guard !completed else { return nil }
            completed = true
            let value = continuation
            continuation = nil
            return value
        }
        value?.resume(with: result)
    }

    func cancel() {
        let value = lock.withLock { () -> Progress? in
            guard !completed else { return nil }
            cancelled = true
            return progress
        }
        value?.cancel()
        finish(.failure(CancellationError()))
    }
}
