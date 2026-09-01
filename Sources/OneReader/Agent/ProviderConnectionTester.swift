import Foundation
import SwiftAgent

@Generable
private struct ProviderProbeArguments: Sendable {
    @Guide(description: "The exact nonce supplied by the host")
    let nonce: String
}

private struct ProviderProbeOutput: PromptRepresentable, Sendable {
    let nonce: String
    var promptRepresentation: Prompt { Prompt("provider-probe-ok:\(nonce)") }
}

private actor ProviderProbeState {
    private var observedNonce: String?
    private var callCount = 0

    func observe(_ nonce: String) throws {
        callCount += 1
        guard callCount == 1 else {
            throw ReadingAgentError.providerUnavailable("probe-tool-call-budget")
        }
        observedNonce = nonce
    }

    func exactlyOnce(with nonce: String) -> Bool {
        callCount == 1 && observedNonce == nonce
    }
}

private struct ProviderCapabilityProbeTool: Tool {
    let state: ProviderProbeState
    let name = "providerCapabilityProbe"
    let description = "Connection-test-only tool. Echo the exact nonce once."

    func call(arguments: ProviderProbeArguments) async throws -> ProviderProbeOutput {
        try await state.observe(arguments.nonce)
        return ProviderProbeOutput(nonce: arguments.nonce)
    }
}

private actor ProviderProbeCallBudget {
    private var structuredResponses = 0
    private var streamingResponses = 0

    func consumeStructuredResponse() throws {
        structuredResponses += 1
        guard structuredResponses <= 2 else {
            throw ReadingAgentError.providerUnavailable("probe-model-call-budget")
        }
    }

    func consumeStreamingResponse() throws {
        streamingResponses += 1
        guard streamingResponses <= 1,
              structuredResponses <= 2,
              structuredResponses + streamingResponses <= 3 else {
            throw ReadingAgentError.providerUnavailable("probe-model-call-budget")
        }
    }
}

private final class BoundedProviderProbeLanguageModel: LanguageModel,
    @unchecked Sendable
{
    let base: any LanguageModel
    let budget: ProviderProbeCallBudget
    let providerKind: ProviderKind

    var isAvailable: Bool { base.isAvailable }

    init(
        base: any LanguageModel,
        budget: ProviderProbeCallBudget,
        providerKind: ProviderKind
    ) {
        self.base = base
        self.budget = budget
        self.providerKind = providerKind
    }

    func supports(locale: Locale) -> Bool {
        base.supports(locale: locale)
    }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        try await budget.consumeStructuredResponse()
        return try await base.generate(transcript: transcript, options: options)
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.budget.consumeStreamingResponse()
                    var normalizer = ProviderStreamEntryNormalizer(
                        providerKind: self.providerKind
                    )
                    for try await entry in self.base.stream(
                        transcript: transcript,
                        options: options
                    ) {
                        try Task.checkCancellation()
                        if let normalized = try normalizer.normalize(entry) {
                            continuation.yield(normalized)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@Generable
private struct ProviderProbeEnvelope: Sendable {
    @Guide(description: "The exact host nonce")
    let nonce: String

    @Guide(description: "The literal value ok")
    let status: String
}

struct ProviderConnectionTester: Sendable {
    let database: LibraryDatabase
    let factory: any ProviderLanguageModelFactory
    let limits: AgentRuntimeLimits

    init(
        database: LibraryDatabase,
        factory: any ProviderLanguageModelFactory = DefaultProviderLanguageModelFactory(),
        limits: AgentRuntimeLimits = .standard
    ) {
        self.database = database
        self.factory = factory
        self.limits = limits
    }

    func test(profile: ProviderProfile, secret: String?) async -> ProviderConnectionTest {
        let started = ContinuousClock.now
        let testedAt = Date.now
        var capabilities = Set<ProviderCapability>()
        var category = "ok"
        var succeeded = false
        let providerRevisionIdentity = (try? ProviderPolicy.revisionIdentity(profile))
            ?? "invalid-provider-revision"
        var transportLease: ProviderEndpointTransportLease?
        do {
            try ProviderPolicy.validateProfile(profile)
            let deadline = started.advanced(by: .seconds(profile.timeoutSeconds))
            let instance = try factory.makeModel(
                profile: profile,
                secret: secret,
                maximumResponseBytes: limits.maxTransportResponseBytes,
                maximumCumulativeResponseBytes: limits.maxTransportResponseBytes
            )
            transportLease = instance.transportLease
            guard instance.model.isAvailable else {
                throw ReadingAgentError.providerUnavailable("model-unavailable")
            }
            let model = BoundedProviderProbeLanguageModel(
                base: instance.model,
                budget: ProviderProbeCallBudget(),
                providerKind: profile.kind
            )
            let nonce = UUID().uuidString.lowercased()
            let state = ProviderProbeState()
            let tool = ProviderCapabilityProbeTool(state: state)
            let session = LanguageModelSession(model: model, tools: [tool]) {
                Instructions("This is a connection and tool-capability test. Call providerCapabilityProbe exactly once with the supplied nonce, then return the requested structured response. Do not include secrets.")
            }
            let step = Generate<String, ProviderProbeEnvelope>(
                session: session,
                options: GenerationOptions(maximumResponseTokens: 256),
                maxRetries: 0,
                transform: { value in
                    "Call providerCapabilityProbe with nonce \(value). Then return nonce \(value) and status ok."
                }
            )
            let envelope = try await withTimeout(
                seconds: try remainingSeconds(until: deadline)
            ) {
                try await step.run(nonce)
            }
            guard envelope.nonce == nonce, envelope.status.lowercased() == "ok" else {
                throw ReadingAgentError.providerUnavailable("structured-probe-mismatch")
            }
            capabilities.formUnion([.connection, .structuredGeneration])
            guard await state.exactlyOnce(with: nonce) else {
                throw ReadingAgentError.providerUnavailable("tool-probe-mismatch")
            }
            capabilities.insert(.toolCalling)

            let streamSession = LanguageModelSession(model: model) {
                Instructions("Return only the word ok. Do not include reasoning.")
            }
            let finalStreamContent = try await withTimeout(
                seconds: try remainingSeconds(until: deadline)
            ) {
                var finalContent: String?
                for try await snapshot in streamSession.streamResponse(
                    to: "ok",
                    options: GenerationOptions(maximumResponseTokens: 32)
                ) {
                    guard snapshot.content.utf8.count <= 4_096 else {
                        throw ReadingAgentError.responseBudgetExceeded(4_096)
                    }
                    finalContent = snapshot.content
                }
                return finalContent
            }
            guard finalStreamContent == "ok" else {
                throw ReadingAgentError.providerUnavailable("stream-probe-mismatch")
            }
            capabilities.insert(.streaming)
            succeeded = true
        } catch {
            if transportLease?.responseLimitViolation() != nil {
                category = "response-budget"
            } else {
                category = AgentRedactor.category(for: error)
            }
        }

        let elapsed = started.duration(to: .now)
        let components = elapsed.components
        let milliseconds = max(
            0,
            Int(components.seconds * 1_000)
                + Int(components.attoseconds / 1_000_000_000_000_000)
        )
        let result = ProviderConnectionTest(
            profileID: profile.id,
            providerRevisionIdentity: providerRevisionIdentity,
            succeeded: succeeded,
            capabilities: capabilities,
            durationMilliseconds: milliseconds,
            category: category,
            testedAt: testedAt
        )
        do {
            guard try database.recordProviderConnectionTest(result) else {
                return ProviderConnectionTest(
                    profileID: profile.id,
                    providerRevisionIdentity: providerRevisionIdentity,
                    succeeded: false,
                    capabilities: [],
                    durationMilliseconds: milliseconds,
                    category: "stale-provider-revision",
                    testedAt: testedAt
                )
            }
            return result
        } catch {
            return ProviderConnectionTest(
                profileID: profile.id,
                providerRevisionIdentity: providerRevisionIdentity,
                succeeded: false,
                capabilities: [],
                durationMilliseconds: milliseconds,
                category: "persistence-failed",
                testedAt: testedAt
            )
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let pair = AsyncThrowingStream<T, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task {
            do {
                pair.continuation.yield(try await operation())
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(max(0.001, seconds)))
                pair.continuation.finish(
                    throwing: ReadingAgentError.providerUnavailable("timeout")
                )
            } catch is CancellationError {
                // The provider completed before the deadline.
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }
        var iterator = pair.stream.makeAsyncIterator()
        guard let first = try await iterator.next() else {
            try Task.checkCancellation()
            throw ReadingAgentError.providerUnavailable("empty-probe")
        }
        return first
    }

    private func remainingSeconds(
        until deadline: ContinuousClock.Instant
    ) throws -> Double {
        let components = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0 else {
            throw ReadingAgentError.providerUnavailable("timeout")
        }
        return seconds
    }
}
