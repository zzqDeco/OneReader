#if DEBUG && os(iOS)
import Foundation
import UIKit
import ZIPFoundation

/// Generated test material, reachable only from a DEBUG UI-test launch. The
/// UUID selects a sibling Library, never the user's production Library.
@MainActor
enum ReaderRecoveryUITestFixture {
    static func root(for runID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneReaderRecoveryUITests", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func materials(in root: URL) throws -> [URL] {
        let inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let pdf = inputs.appendingPathComponent("Recovery PDF.pdf")
        if !FileManager.default.fileExists(atPath: pdf.path) {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 1_600))
            let data = renderer.pdfData { context in
                for page in 1...6 {
                    context.beginPage()
                    for row in 0..<30 {
                        let y = CGFloat(44 + row * 49)
                        let text = "PDF page \(page) / paragraph \(row + 1)\nVisible recovery marker \(page)-\(row + 1)"
                        (text as NSString).draw(
                            in: CGRect(x: 30, y: y, width: 360, height: 44),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.black]
                        )
                    }
                }
            }
            try data.write(to: pdf, options: .atomic)
        }
        let html = inputs.appendingPathComponent("Recovery HTML.html")
        if !FileManager.default.fileExists(atPath: html.path) {
            try chapter(title: "Recovery HTML", prefix: "HTML").write(to: html, atomically: true, encoding: .utf8)
        }
        let epub = inputs.appendingPathComponent("Recovery EPUB.epub")
        if !FileManager.default.fileExists(atPath: epub.path) {
            let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """
            let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">onereader-recovery-fixture</dc:identifier><dc:title>Recovery EPUB</dc:title><dc:language>en</dc:language></metadata><manifest><item id="first" href="first.xhtml" media-type="application/xhtml+xml"/><item id="second" href="second.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>
            """
            let entries = [
                ("mimetype", "application/epub+zip"),
                ("META-INF/container.xml", container),
                ("OEBPS/content.opf", package),
                ("OEBPS/first.xhtml", chapter(title: "EPUB First Chapter", prefix: "EPUB First")),
                ("OEBPS/second.xhtml", chapter(title: "EPUB Second Chapter", prefix: "EPUB Second")),
            ]
            let staging = inputs.appendingPathComponent("\(UUID().uuidString).epub")
            defer { try? FileManager.default.removeItem(at: staging) }
            let archive = try Archive(url: staging, accessMode: .create)
            for (path, text) in entries {
                let data = Data(text.utf8)
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .none
                ) { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<min(start + size, data.count))
                }
            }
            try FileManager.default.moveItem(at: staging, to: epub)
        }
        let markdown = inputs.appendingPathComponent("Recovery Markdown.md")
        if !FileManager.default.fileExists(atPath: markdown.path) {
            let text = (1...120).map { "## Markdown section \($0)\n\nVisible marker \($0). This managed Markdown fixture verifies the actual source anchor after scrolling, leaving the Space, and restarting the application.\n" }.joined(separator: "\n")
            try text.write(to: markdown, atomically: true, encoding: .utf8)
        }
        return [pdf, html, epub, markdown]
    }

    private static func chapter(title: String, prefix: String) -> String {
        let paragraphs = (1...120).map { number in
            "<p id=\"marker-\(number)\">\(prefix) paragraph \(number). A unique visible reading marker verifies scrolling and restoration of the actual document viewport. Reading position must survive a different Space and a fresh application process.</p>"
        }.joined(separator: "\n")
        return "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title></head><body><h1>\(title)</h1>\(paragraphs)</body></html>"
    }
}
#endif
