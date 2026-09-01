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
| Reading Agent session and turn lifecycle | [Reading Agent runtime](Sources/OneReader/Agent/ReadingAgentRuntime.swift.md) |
| Agent domain records and hard budgets | [Agent models](Sources/OneReader/Agent/AgentModels.swift.md) |
| SwiftAgent projection and bounded model bridge | [SwiftAgent model driver](Sources/OneReader/Agent/SwiftAgentModelDriver.swift.md) |
| Apple Foundation Models trust separation | [Apple on-device model](Sources/OneReader/Agent/AppleOnDeviceLanguageModel.swift.md) |
| Agent budgets and context projection | [Runtime control](Sources/OneReader/Agent/RuntimeControl.swift.md) |
| Provider validation and disclosure identity | [Provider policy](Sources/OneReader/Agent/ProviderPolicy.swift.md) |
| Provider capability probe and revision CAS | [Provider connection tester](Sources/OneReader/Agent/ProviderConnectionTester.swift.md) |
| Provider endpoint and redirect boundary | [Provider endpoint transport](Sources/OneReader/Agent/ProviderEndpointTransport.swift.md) |
| Read-only model tool boundary | [Reading tools](Sources/OneReader/Agent/ReadingTools.swift.md) |
| Structured-output evidence gate | [Agent output validator](Sources/OneReader/Agent/AgentOutputValidator.swift.md) |
| Agent audit and Provider persistence | [Agent persistence](Sources/OneReader/Persistence/AgentPersistence.swift.md) |
| Transitional progress file | [Progress store](Sources/OneReader/Persistence/ProgressStore.swift.md) |

Add a source note when a file owns a durable contract, security boundary,
persistence format, or cross-feature orchestration responsibility.
