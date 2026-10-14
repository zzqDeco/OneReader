#if os(iOS)
import UIKit
import XCTest
@testable import OneReader

@MainActor
final class LocalOCRDeviceTests: XCTestCase {
    func testLocalPrintedChineseAndEnglishRecognitionOnDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneReader-OCR-Device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 700)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
            for (line, y) in [("OneReader local OCR", 160.0), ("离线识别与阅读", 360.0)] {
                (line as NSString).draw(at: CGPoint(x: 80, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 58), .foregroundColor: UIColor.black
                ])
            }
        }
        let data = try XCTUnwrap(image.pngData())
        let url = root.appendingPathComponent("printed.png")
        try data.write(to: url)
        let source = Source(displayName: "printed.png", originKind: .localFile, originURL: url, managedState: .ready)
        let snapshot = SourceSnapshot(sourceID: source.id, revision: AdapterUtilities.sha256(data), observedAt: .now, origin: url)
        let result = try await VisionOCREngine().recognize(context: AdapterContext(source: source,
            snapshot: snapshot, managedURL: url, derivedRootURL: root), pageIndex: 0, settings: OCRSettings())
        try result.validate()
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("OneReader local OCR"))
        XCTAssertTrue(result.text.contains("离线识别"))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
#endif
