import Foundation

struct QuickLookAdapter: ProbingAdapter, RenderingAdapter, ResolvingAdapter {
    static let id = "onereader.quicklook"

    let descriptor = AdapterDescriptor(
        id: id,
        version: "1.0.0",
        displayName: "Quick Look Fallback",
        probeRule: AdapterProbeRule(
            sourceOrigins: [.localFile, .remoteURL]
        ),
        capabilities: [.probe, .render, .resolve],
        limitations: [
            "只保证来源级书签和笔记",
            "不提供结构化全文搜索、高亮或 AI 引用",
        ]
    )

    func probe(_ context: AdapterContext) async throws -> AdapterProbeMatch? {
        guard !TextAdapterCore.isDirectory(context.managedURL) else { return nil }
        return AdapterProbeMatch(
            adapterID: descriptor.id,
            confidence: 0.1,
            evidence: [
                ProbeEvidence(
                    id: "\(descriptor.id):fallback",
                    adapterID: descriptor.id,
                    rule: "readable-file-fallback",
                    detail: context.source.displayName,
                    confidence: 0.1
                )
            ],
            reason: "没有结构化适配器时交给系统 Quick Look"
        )
    }

    func presentation(
        in context: AdapterContext,
        at locator: Locator?
    ) async throws -> PresentationDocument {
        let resolvedLocator = locator ?? sourceLocator(context)
        try context.validate(resolvedLocator, adapterID: descriptor.id)
        return PresentationDocument(
            id: "presentation:\(resolvedLocator.stableID)",
            surface: .quickLook,
            locator: resolvedLocator,
            title: context.source.displayName,
            mediaType: context.declaredMediaType ?? "application/octet-stream",
            content: nil,
            contentURL: context.managedURL,
            baseURL: nil,
            limitations: descriptor.limitations
        )
    }

    func resolve(
        _ locator: Locator,
        in context: AdapterContext
    ) async throws -> LocatorResolution {
        guard locator.sourceID == context.source.id,
              locator.adapterID == descriptor.id,
              locator.schemaVersion == Locator.currentSchemaVersion else {
            throw AdapterError.invalidLocator("Quick Look Source、Adapter 或 schema 不匹配")
        }
        if locator.snapshotID == context.snapshot.id {
            return LocatorResolution(
                state: .current,
                requested: locator,
                resolved: locator,
                reason: "Snapshot 与 Locator 一致"
            )
        }
        return LocatorResolution(
            state: .relocated,
            requested: locator,
            resolved: sourceLocator(context),
            reason: "Quick Look 仅恢复到新 Snapshot 的来源级位置"
        )
    }

    private func sourceLocator(_ context: AdapterContext) -> Locator {
        Locator(
            sourceID: context.source.id,
            snapshotID: context.snapshot.id,
            adapterID: descriptor.id,
            payload: [:],
            structuralPath: nil,
            textQuote: nil,
            fingerprint: context.snapshot.digest
        )
    }
}
