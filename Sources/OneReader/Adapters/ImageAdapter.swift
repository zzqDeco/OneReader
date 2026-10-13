import Foundation
import ImageIO

struct ImageAdapter: ProbingAdapter, RevisionAdapter, ListingAdapter, RenderingAdapter, ResolvingAdapter {
    static let id = "onereader.image"
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    let descriptor = AdapterDescriptor(id: id, version: "1.0.0", displayName: "原始图像",
        probeRule: AdapterProbeRule(filenameExtensions: extensions, mediaTypes: ["image/jpeg", "image/png", "image/heic"], sourceOrigins: [.localFile, .remoteURL], magicPrefixes: []),
        capabilities: [.probe, .revision, .list, .render, .resolve],
        limitations: ["原始图像没有文字层，可在本机识别后搜索和标注。"])

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard Self.extensions.contains(context.filenameExtension),
              let source = CGImageSourceCreateWithURL(context.managedURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else { return nil }
        return AdapterProbeMatch(adapterID: Self.id, confidence: 0.99,
            evidence: [ProbeEvidence(id: "image-format", adapterID: Self.id, rule: "imageio", detail: context.filenameExtension, confidence: 0.99)],
            reason: "ImageIO 可读取单张原始图像")
    }

    func verifyRevision(in context: AdapterContext) async throws {
        let digest = AdapterUtilities.sha256(try Data(contentsOf: context.managedURL, options: [.mappedIfSafe]))
        guard context.snapshot.revisionKind != .contentDigest || digest == context.snapshot.revision else {
            throw AdapterError.unsupportedContent("图像与托管快照不一致")
        }
    }

    func listContent(in context: AdapterContext, under locator: Locator?, limit: Int) async throws -> [ContentNode] {
        [ContentNode(id: locatorFor(context).stableID, title: context.source.displayName, kind: .page,
            locator: locatorFor(context), depth: 0, order: 0, mediaType: "image/\(context.filenameExtension)", isReadable: true)]
    }

    func presentation(in context: AdapterContext, at locator: Locator?) async throws -> PresentationDocument {
        let anchor = locator ?? locatorFor(context)
        try context.validate(anchor, adapterID: Self.id)
        return PresentationDocument(id: "presentation:\(anchor.stableID)", surface: .nativeImage, locator: anchor,
            title: context.source.displayName, mediaType: "image/\(context.filenameExtension)", content: nil,
            contentURL: context.managedURL, baseURL: nil, limitations: descriptor.limitations)
    }

    func resolve(_ locator: Locator, in context: AdapterContext) async throws -> LocatorResolution {
        try context.validate(locator, adapterID: Self.id)
        return LocatorResolution(state: .current, requested: locator, resolved: locator, reason: "原始图像快照一致")
    }

    private func locatorFor(_ context: AdapterContext) -> Locator {
        Locator(sourceID: context.source.id, snapshotID: context.snapshot.id, adapterID: Self.id,
                payload: ["pageIndex": "0"], structuralPath: "image/0")
    }
}
