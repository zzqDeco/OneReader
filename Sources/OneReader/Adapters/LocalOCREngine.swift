import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Vision

protocol LocalOCREngine: Sendable {
    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage
}

final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    private var continuation: CheckedContinuation<OCRPage, any Error>?

    func begin(_ continuation: CheckedContinuation<OCRPage, any Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<OCRPage, any Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil; request = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    func attach(_ request: VNRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.request = request
    }
    func cancel() {
        interrupt(CancellationError())
    }
    func expire() {
        interrupt(OCRError.recognitionTimedOut)
    }
    private func interrupt(_ error: any Error) {
        lock.lock(); cancelled = true; let request = request
        let continuation = continuation
        self.continuation = nil; self.request = nil
        lock.unlock()
        request?.cancel()
        continuation?.resume(throwing: error)
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class OCRWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true; return true
    }
    func release() { lock.lock(); busy = false; lock.unlock() }
}

struct VisionOCREngine: LocalOCREngine {
    // Revision 3 stalls in TextRecognition on the validated macOS 27 host, including
    // an independent AppKit process. Revision 2 still supports accurate Chinese and
    // English and passes the same real fixture. Pin the actual pipeline in evidence
    // rather than silently substituting Vision's Latin-only fast recognition mode.
#if os(macOS)
    private static let requestRevision = 2 // Public VNRecognizeTextRequestRevision2 value.
#else
    private static let requestRevision = VNRecognizeTextRequestRevision3
#endif
    static var engineVersion: String { "apple-vision-accurate-r\(requestRevision)-cpu-v1" }
    // A single queue bounds both decode memory and Vision compute across documents.
    private static let queue = DispatchQueue(label: "OneReader.LocalOCR", qos: .utility)
    private static let gate = OCRWorkerGate()

    func recognize(context: AdapterContext, pageIndex: Int, settings: OCRSettings) async throws -> OCRPage {
        guard Self.gate.acquire() else {
            throw OCRError.engineUnavailable
        }
        let cancellation = OCRCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancellation.begin(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) { cancellation.expire() }
                Self.queue.async {
                    defer { Self.gate.release() }
                    do {
                        try cancellation.check()
                        let result = try autoreleasepool {
                            try Self.recognizeSync(context: context, pageIndex: pageIndex,
                                                   settings: settings, cancellation: cancellation)
                        }
                        try cancellation.check()
                        cancellation.finish(.success(result))
                    } catch { cancellation.finish(.failure(error)) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func pageCount(context: AdapterContext) throws -> Int {
        if context.filenameExtension == "pdf" {
            guard let document = CGPDFDocument(context.managedURL as CFURL), !document.isEncrypted,
                  document.numberOfPages > 0 else { throw OCRError.invalidInput("PDF 已加密、损坏或没有页面。") }
            return document.numberOfPages
        }
        guard ImageAdapter.extensions.contains(context.filenameExtension),
              let source = CGImageSourceCreateWithURL(context.managedURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw OCRError.invalidInput("仅支持 PDF 和单张 JPEG、PNG、HEIC 图像。")
        }
        return 1
    }

    private static func recognizeSync(context: AdapterContext, pageIndex: Int, settings: OCRSettings,
                                      cancellation: OCRCancellation) throws -> OCRPage {
        let count = try pageCount(context: context)
        guard (0..<count).contains(pageIndex) else { throw OCRError.invalidInput("页码超出范围。") }
        let raster = try rasterize(context: context, pageIndex: pageIndex)
        if !settings.replaceNativeText, context.filenameExtension == "pdf",
           let text = PDFDocument(url: context.managedURL)?.page(at: pageIndex)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return OCRPage(pageIndex: pageIndex, inputDigest: raster.digest, geometry: raster.geometry,
                           spans: [], usesNativeText: true)
        }
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        guard VNRecognizeTextRequest.supportedRevisions.contains(Self.requestRevision) else {
            throw OCRError.invalidInput("此系统未提供 OneReader 已验证的本机文字识别版本。")
        }
        request.revision = Self.requestRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Prefer predictable local background processing in both UI and headless runs.
        // Select only CPU devices that Vision explicitly reports as supported.
        for (stage, devices) in try request.supportedComputeStageDevices {
            guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                throw OCRError.invalidInput("此设备没有可用的本地 CPU 文字识别能力。")
            }
            request.setComputeDevice(cpu, for: stage)
        }
        let supported = try Set(request.supportedRecognitionLanguages())
        guard !settings.languages.isEmpty, settings.languages.allSatisfy(supported.contains) else {
            throw OCRError.invalidInput("当前系统不支持所选识别语言。可选择简体中文和英文；请检查系统语言资源。")
        }
        request.recognitionLanguages = settings.languages
        try cancellation.attach(request)
        try VNImageRequestHandler(cgImage: raster.image, orientation: .up).perform([request])
        try cancellation.check()
        let observations = (request.results ?? []).sorted {
            // Vision lines have a bottom-left origin. Group nearby baselines before left-to-right.
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var spans: [OCRSpan] = []
        for (order, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            spans.append(OCRSpan(id: UUID().uuidString.lowercased(), text: candidate.string,
                confidence: Double(candidate.confidence),
                bounds: try raster.geometry.sourceRectangle(normalized: observation.boundingBox), order: order))
        }
        let page = OCRPage(pageIndex: pageIndex, inputDigest: raster.digest, geometry: raster.geometry,
                           spans: spans, usesNativeText: false)
        try page.validate()
        return page
    }

    private struct Raster {
        let image: CGImage
        let geometry: OCRGeometry
        let digest: String
    }

    private static func rasterize(context: AdapterContext, pageIndex: Int) throws -> Raster {
        if context.filenameExtension == "pdf" {
            guard let document = CGPDFDocument(context.managedURL as CFURL),
                  let page = document.page(at: pageIndex + 1) else { throw OCRError.invalidInput("PDF 页面不可读。") }
            let bounds = page.getBoxRect(.cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                  bounds.width < 100_000, bounds.height < 100_000 else { throw OCRError.resourceLimit }
            let rotated = page.rotationAngle % 180 != 0
            let width = rotated ? bounds.height : bounds.width
            let height = rotated ? bounds.width : bounds.height
            let scale = min(3, Double(OCRSettings.maximumRasterDimension) / max(width, height))
            let pixelWidth = max(1, Int((width * scale).rounded(.up)))
            let pixelHeight = max(1, Int((height * scale).rounded(.up)))
            guard let canvas = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw OCRError.resourceLimit
            }
            canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            let transform = page.getDrawingTransform(.cropBox,
                rect: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight), rotate: 0, preserveAspectRatio: true)
            canvas.concatenate(transform); canvas.drawPDFPage(page)
            guard let image = canvas.makeImage() else { throw OCRError.resourceLimit }
            return try makeRaster(image: image, geometry: OCRGeometry(bounds: bounds,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, transform: transform))
        }
        guard let source = CGImageSourceCreateWithURL(context.managedURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= OCRSettings.maximumInputPixels / height else {
            throw OCRError.resourceLimit
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: OCRSettings.maximumRasterDimension]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OCRError.invalidInput("图像无法解码。")
        }
        // Image coordinates are EXIF-normalized unit coordinates, independent of screen scale.
        return try makeRaster(image: image, geometry: OCRGeometry(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            pixelWidth: image.width, pixelHeight: image.height,
            transform: CGAffineTransform(scaleX: Double(image.width), y: Double(image.height))))
    }

    private static func makeRaster(image: CGImage, geometry: OCRGeometry) throws -> Raster {
        guard let data = image.dataProvider?.data else { throw OCRError.invalidInput("图像字节不可读。") }
        return Raster(image: image, geometry: geometry,
                      digest: AdapterUtilities.sha256(data as Data))
    }
}

actor OCRService {
    private let database: LibraryDatabase
    private let engine: any LocalOCREngine

    init(database: LibraryDatabase, engine: any LocalOCREngine = VisionOCREngine()) {
        self.database = database; self.engine = engine
    }

    func run(context: AdapterContext, pages: [Int], settings: OCRSettings, resuming: OCRJob? = nil,
             progress: @Sendable (OCRJob) async -> Void) async throws -> OCRRevision? {
        let count = try VisionOCREngine.pageCount(context: context)
        if context.filenameExtension == "pdf" { try await PDFAdapter().verifyRevision(in: context) }
        else { try await ImageAdapter().verifyRevision(in: context) }
        guard pages.allSatisfy({ (0..<count).contains($0) }) else { throw OCRError.invalidInput("页码范围无效。") }
        let values = try context.derivedRootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes < 2 * 1024 * 1024 * 1024 {
            throw OCRError.resourceLimit
        }
        var job = OCRJob(id: UUID().uuidString.lowercased(), sourceID: context.source.id,
            snapshotID: context.snapshot.id, pageIndices: pages, settings: settings,
            completedPages: [], failedPages: [], state: .running, createdAt: .now, updatedAt: .now)
        try database.startOCRJob(job); await progress(job)
        do {
            if let resuming, resuming.sourceID == context.source.id,
               resuming.snapshotID == context.snapshot.id, resuming.settings == settings {
                for page in try database.ocrDraftPages(jobID: resuming.id) where pages.contains(page.pageIndex) {
                    job = try database.saveOCRPage(page, jobID: job.id)
                }
            }
            pageLoop: for pageIndex in pages where !job.completedPages.contains(pageIndex) {
                try Task.checkCancellation()
                do {
                    let page = try await engine.recognize(context: context, pageIndex: pageIndex, settings: settings)
                    try Task.checkCancellation()
                    job = try database.saveOCRPage(page, jobID: job.id)
                } catch is CancellationError { throw CancellationError() }
                catch let error as OCRError where error == .staleJob { throw error }
                catch let error as OCRError where error == .engineUnavailable || error == .recognitionTimedOut {
                    job = try database.markOCRPageFailed(pageIndex, jobID: job.id, reason: error.localizedDescription)
                    await progress(job)
                    break pageLoop
                }
                catch { job = try database.markOCRPageFailed(pageIndex, jobID: job.id, reason: error.localizedDescription) }
                await progress(job)
            }
            let state: OCRJobState = job.failedPages.isEmpty && job.completedPages.count == pages.count ? .completed : .partial
            if context.filenameExtension == "pdf" { try await PDFAdapter().verifyRevision(in: context) }
            else { try await ImageAdapter().verifyRevision(in: context) }
            let result = try database.finishOCRJob(job.id, state: state)
            job.state = state; await progress(job)
            return result
        } catch is CancellationError {
            do {
                if context.filenameExtension == "pdf" { try await PDFAdapter().verifyRevision(in: context) }
                else { try await ImageAdapter().verifyRevision(in: context) }
                let result = try database.finishOCRJob(job.id, state: .cancelled)
                job.state = .cancelled; await progress(job)
                return result
            } catch {
                try? database.abandonOCRJob(job.id)
                throw error
            }
        } catch {
            try? database.abandonOCRJob(job.id)
            throw error
        }
    }
}
