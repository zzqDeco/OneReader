import Foundation
import SwiftAgent

@Generable
struct GeneratedReadingToolArguments: Sendable {
    @Guide(description: "Source identifier from listSources; empty when not needed")
    let sourceID: String

    @Guide(description: "Exact snapshot identifier from listSources; empty when not needed")
    let snapshotID: String

    @Guide(description: "Registered adapter identifier; empty when not needed")
    let adapterID: String

    @Guide(description: "A complete OneReader Locator encoded as JSON; empty when not needed")
    let locatorJSON: String

    @Guide(description: "Search query; empty when not needed")
    let query: String

    @Guide(description: "Requested item count, never above documented limits")
    let limit: Int

    @Guide(description: "Artifact handle returned by a previous tool; empty when not needed")
    let artifactID: String

    @Guide(description: "Byte offset when reading an artifact handle")
    let offset: Int
}

extension GeneratedReadingToolArguments {
    var domainArguments: ReadingToolArguments {
        ReadingToolArguments(
            sourceID: sourceID.nilIfEmpty,
            snapshotID: snapshotID.nilIfEmpty,
            adapterID: adapterID.nilIfEmpty,
            locatorJSON: locatorJSON.nilIfEmpty,
            query: query.nilIfEmpty,
            limit: limit > 0 ? limit : nil,
            artifactID: artifactID.nilIfEmpty,
            offset: max(0, offset)
        )
    }
}

struct ReadingToolPromptOutput: PromptRepresentable, Sendable {
    let value: String

    var promptRepresentation: Prompt { Prompt(value) }
}

actor ReadingToolRuntime {
    let host: ReadingToolHost
    let request: AgentRunRequest
    let runID: String
    let generation: Int
    let limits: AgentRuntimeLimits
    let clock: AgentGenerationClock
    let budget: AgentRunBudget
    let gate: ToolConcurrencyGate
    let recorder: AgentEventRecorder

    init(
        host: ReadingToolHost,
        request: AgentRunRequest,
        runID: String,
        generation: Int,
        limits: AgentRuntimeLimits,
        clock: AgentGenerationClock,
        budget: AgentRunBudget,
        gate: ToolConcurrencyGate,
        recorder: AgentEventRecorder
    ) {
        self.host = host
        self.request = request
        self.runID = runID
        self.generation = generation
        self.limits = limits
        self.clock = clock
        self.budget = budget
        self.gate = gate
        self.recorder = recorder
    }

    func execute(
        tool: ReadingToolName,
        arguments: GeneratedReadingToolArguments
    ) async throws -> ReadingToolPromptOutput {
        try await clock.check(generation)
        let callNumber = try await budget.consumeToolCall()
        try await recorder.emit(
            .toolStarted,
            phase: phase(for: tool),
            message: "读取工具开始：\(tool.rawValue)",
            metadata: [
                "tool": tool.rawValue,
                "call": String(callNumber),
                "sourceID": arguments.sourceID,
                "snapshotID": arguments.snapshotID,
            ]
        )

        let result: ReadingToolResult
        do {
            result = try await gate.withPermit { [host, request, runID, limits] in
                try await host.execute(
                    tool,
                    arguments: arguments.domainArguments,
                    spaceID: request.spaceID,
                    snapshotManifest: request.snapshotManifest,
                    runID: runID,
                    limits: limits
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ReadingAgentError where error == .runNotCurrent {
            throw error
        } catch {
            let category = AgentRedactor.category(for: error)
            _ = try? await recorder.emit(
                .toolFinished,
                phase: phase(for: tool),
                message: "读取工具未能完成：\(tool.rawValue)",
                metadata: ["tool": tool.rawValue, "category": category]
            )
            throw ReadingAgentError.toolExecutionFailed(category)
        }
        try await clock.check(generation)

        let encoded = try Self.encoder.encode(result)
        try await recorder.appendTranscript(role: .tool, content: encoded)
        if let artifactID = result.artifactID {
            try await recorder.emit(
                .artifactCreated,
                phase: phase(for: tool),
                message: "较大读取结果已保存为可分段读取的 Artifact。",
                metadata: [
                    "tool": tool.rawValue,
                    "artifactID": artifactID,
                    "digest": result.digest,
                    "byteCount": String(result.byteCount),
                ]
            )
        }
        try await recorder.emit(
            .toolFinished,
            phase: phase(for: tool),
            message: "读取工具完成：\(tool.rawValue)",
            metadata: [
                "tool": tool.rawValue,
                "digest": result.digest,
                "byteCount": String(result.byteCount),
                "truncated": String(result.truncated),
            ]
        )
        return ReadingToolPromptOutput(value: result.content)
    }

    private func phase(for tool: ReadingToolName) -> String {
        switch tool {
        case .listSources, .inspectCapabilities: "probe"
        case .listContent, .readFragment, .searchContent: "scout"
        case .resolveLocator: "resolve"
        case .inspectPresentation: "presentation"
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

protocol RuntimeReadingTool: Tool where Arguments == GeneratedReadingToolArguments,
                                         Output == ReadingToolPromptOutput {
    var runtime: ReadingToolRuntime { get }
    var toolName: ReadingToolName { get }
}

extension RuntimeReadingTool {
    func call(arguments: GeneratedReadingToolArguments) async throws -> ReadingToolPromptOutput {
        try await runtime.execute(tool: toolName, arguments: arguments)
    }
}

struct ListSourcesTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.listSources
    let name = ReadingToolName.listSources.rawValue
    let description = "List the sources and exact snapshots already attached to this Reading Space. Read-only."
}

struct InspectCapabilitiesTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.inspectCapabilities
    let name = ReadingToolName.inspectCapabilities.rawValue
    let description = "Inspect registered adapter descriptors and the deterministic plan installed for a snapshot. Read-only."
}

struct ListContentTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.listContent
    let name = ReadingToolName.listContent.rawValue
    let description = "List bounded content nodes through the installed adapter plan. Read-only."
}

struct ReadFragmentTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.readFragment
    let name = ReadingToolName.readFragment.rawValue
    let description = "Read at most 16K characters at an exact Locator, or a bounded segment of an Artifact handle. Read-only."
}

struct SearchContentTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.searchContent
    let name = ReadingToolName.searchContent.rawValue
    let description = "Search a current snapshot and return at most 20 evidence hits with exact Locators. Read-only."
}

struct ResolveLocatorTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.resolveLocator
    let name = ReadingToolName.resolveLocator.rawValue
    let description = "Resolve an existing Locator against an explicitly named snapshot without changing it. Read-only."
}

struct InspectPresentationTool: RuntimeReadingTool {
    let runtime: ReadingToolRuntime
    let toolName = ReadingToolName.inspectPresentation
    let name = ReadingToolName.inspectPresentation.rawValue
    let description = "Inspect the bounded, sanitized presentation metadata for a Locator. Read-only."
}

enum ReadingAgentToolRegistry {
    static func tools(runtime: ReadingToolRuntime) -> [any Tool] {
        [
            ListSourcesTool(runtime: runtime),
            InspectCapabilitiesTool(runtime: runtime),
            ListContentTool(runtime: runtime),
            ReadFragmentTool(runtime: runtime),
            SearchContentTool(runtime: runtime),
            ResolveLocatorTool(runtime: runtime),
            InspectPresentationTool(runtime: runtime),
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
