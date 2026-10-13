import CoreGraphics
import Foundation

enum OCRError: LocalizedError, Equatable {
    case invalidInput(String)
    case staleJob
    case missingRevision
    case resourceLimit
    case engineUnavailable
    case recognitionTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidInput(let reason): reason
        case .staleJob: "识别任务的来源版本已改变，请重新开始。"
        case .missingRevision: "这份识别结果已不可用；不会用其他版本冒充原引用。"
        case .resourceLimit: "超过本地识别资源限制，请缩小页码范围或释放磁盘空间。"
        case .engineUnavailable: "本机识别引擎仍在结束上次请求；若长时间未恢复，请重启 App 后重试。"
        case .recognitionTimedOut: "本页识别超时，已停止等待；已完成的页面会保留。"
        }
    }
}

struct OCRRectangle: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    var locatorValue: String { [x, y, width, height].map { String($0) }.joined(separator: ",") }
}

/// Original PDF coordinates (bottom-left, unrotated) to raster pixels (bottom-left).
/// Storing the actual affine transform also handles non-zero crop origins and rotations.
struct OCRGeometry: Codable, Hashable, Sendable {
    let sourceBounds: OCRRectangle
    let pixelWidth: Int
    let pixelHeight: Int
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double

    init(bounds: CGRect, pixelWidth: Int, pixelHeight: Int, transform: CGAffineTransform) {
        sourceBounds = OCRRectangle(bounds)
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        a = transform.a; b = transform.b; c = transform.c; d = transform.d
        tx = transform.tx; ty = transform.ty
    }

    var transform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    var isValid: Bool {
        sourceBounds.isValid && pixelWidth > 0 && pixelHeight > 0
            && pixelWidth <= 4096 && pixelHeight <= 4096
            && [a, b, c, d, tx, ty].allSatisfy(\.isFinite) && abs(a * d - b * c) > 0.00000001
    }

    func sourceRectangle(normalized: CGRect) throws -> OCRRectangle {
        guard isValid, !normalized.isNull, !normalized.isEmpty,
              [normalized.minX, normalized.minY, normalized.width, normalized.height].allSatisfy(\.isFinite) else {
            throw OCRError.invalidInput("识别坐标无效。")
        }
        let clipped = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: clipped.minX * Double(pixelWidth), y: clipped.minY * Double(pixelHeight),
                            width: clipped.width * Double(pixelWidth), height: clipped.height * Double(pixelHeight))
        let original = pixels.applying(transform.inverted()).intersection(sourceBounds.rect)
        let result = OCRRectangle(original)
        guard result.isValid else { throw OCRError.invalidInput("识别区域不在原始页面内。") }
        return result
    }
}

struct OCRSettings: Codable, Hashable, Sendable {
    var languages: [String] = ["zh-Hans", "en-US"]
    var replaceNativeText = false
    static var engineVersion: String { VisionOCREngine.engineVersion }
    static let maximumPagesPerJob = 1000
    static let maximumInputPixels = 100_000_000
    static let maximumRasterDimension = 2400
    static let maximumRevisionBytes = 32 * 1024 * 1024
}

struct OCRSpan: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let text: String
    let confidence: Double
    let bounds: OCRRectangle
    let order: Int
}

struct OCRPage: Identifiable, Codable, Hashable, Sendable {
    var id: Int { pageIndex }
    let pageIndex: Int
    let inputDigest: String
    let geometry: OCRGeometry
    let spans: [OCRSpan]
    let usesNativeText: Bool
    var text: String { spans.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n") }

    func validate() throws {
        guard pageIndex >= 0, geometry.isValid, !inputDigest.isEmpty,
              spans.count <= 20_000, text.utf8.count <= 1_048_576,
              Set(spans.map(\.id)).count == spans.count,
              spans.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty && $0.bounds.isValid
                  && $0.confidence.isFinite && (0...1).contains($0.confidence)
                  && geometry.sourceBounds.rect.insetBy(dx: -0.01, dy: -0.01).contains($0.bounds.rect) }) else {
            throw OCRError.invalidInput("识别页未通过宿主验证。")
        }
    }
}

enum OCRJobState: String, Codable, Sendable { case running, completed, partial, cancelled, interrupted, failed }

struct OCRJob: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let snapshotID: String
    let pageIndices: [Int]
    let settings: OCRSettings
    var completedPages: [Int]
    var failedPages: [Int]
    var failureReasons: [Int: String] = [:]
    var state: OCRJobState
    let createdAt: Date
    var updatedAt: Date
}

extension OCRJob {
    private enum CodingKeys: String, CodingKey {
        case id, sourceID, snapshotID, pageIndices, settings, completedPages, failedPages
        case failureReasons, state, createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        snapshotID = try values.decode(String.self, forKey: .snapshotID)
        pageIndices = try values.decode([Int].self, forKey: .pageIndices)
        settings = try values.decode(OCRSettings.self, forKey: .settings)
        completedPages = try values.decode([Int].self, forKey: .completedPages)
        failedPages = try values.decode([Int].self, forKey: .failedPages)
        failureReasons = try values.decodeIfPresent([Int: String].self, forKey: .failureReasons) ?? [:]
        state = try values.decode(OCRJobState.self, forKey: .state)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

struct OCRRevision: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let snapshotID: String
    let jobID: String
    let engineVersion: String
    let settings: OCRSettings
    let pages: [OCRPage]
    let createdAt: Date

    func locator(page: OCRPage, span: OCRSpan? = nil) -> Locator {
        var payload = ["ocrRevisionID": id, "ocrSchema": "1", "pageIndex": String(page.pageIndex),
                       "derivedText": "ocr"]
        if let span {
            payload["ocrSpanID"] = span.id
            payload["rect"] = span.bounds.locatorValue
        }
        return Locator(sourceID: sourceID, snapshotID: snapshotID, adapterID: OCRAdapter.id,
                       payload: payload, structuralPath: "page/\(page.pageIndex)",
                       textQuote: span.map { TextQuote(prefix: nil, exact: $0.text, suffix: nil) },
                       fingerprint: span.map { AdapterUtilities.sha256($0.text) })
    }
}
