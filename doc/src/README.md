# Source Notes

Source notes record narrow file ownership and invariants. They are not a second
architecture document.

| Source area | Note |
| --- | --- |
| Domain contracts and planning | [Domain models](Sources/OneReader/Domain/Models.swift.md) |
| GitHub repository access | [GitHub book source](Sources/OneReader/Sources/GitHubBookSource.swift.md) |
| PDF loading and outline mapping | [PDF book source](Sources/OneReader/Sources/PDFBookSource.swift.md) |
| Application state | [App model](Sources/OneReader/App/AppModel.swift.md) |
| Native workspace | [Workspace view](Sources/OneReader/UI/WorkspaceView.swift.md) |
| Application Support layout | [Library paths](Sources/OneReader/Persistence/ApplicationSupportLayout.swift.md) |
| Database and migrations | [Library database](Sources/OneReader/Persistence/LibraryDatabase.swift.md) |
| Atomic managed import | [Managed Library](Sources/OneReader/Persistence/ManagedLibrary.swift.md) |
| Adapter probing and capability routing | [Adapter registry](Sources/OneReader/Adapters/AdapterRegistry.swift.md) |
| Secure ZIP/EPUB extraction | [Secure archive extractor](Sources/OneReader/Adapters/SecureArchiveExtractor.swift.md) |
| Remote web and GitHub snapshots | [Remote source importer](Sources/OneReader/Sources/RemoteSourceImporter.swift.md) |
| Unified native presentation safety | [Adapter presentation](Sources/OneReader/UI/AdapterPresentationView.swift.md) |
| Transitional progress file | [Progress store](Sources/OneReader/Persistence/ProgressStore.swift.md) |

Add a source note when a file owns a durable contract, security boundary,
persistence format, or cross-feature orchestration responsibility.
