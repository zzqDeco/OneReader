import Foundation
import SwiftAgent
import XCTest
@testable import OneReader

final class AgentRuntimeControlTests: XCTestCase {
    func testBudgetStopsAtConfiguredModelAndToolLimits() async throws {
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            maxToolCalls: 3,
            maxConcurrentTools: 4
        )
        let budget = AgentRunBudget(limits: limits)

        let modelRoundOne = try await budget.consumeModelRound()
        let modelRoundTwo = try await budget.consumeModelRound()
        XCTAssertEqual(modelRoundOne, 1)
        XCTAssertEqual(modelRoundTwo, 2)
        do {
            _ = try await budget.consumeModelRound()
            XCTFail("Expected model budget failure")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .modelRoundBudgetExceeded(2))
        }

        let toolCallOne = try await budget.consumeToolCall()
        let toolCallTwo = try await budget.consumeToolCall()
        let toolCallThree = try await budget.consumeToolCall()
        XCTAssertEqual(toolCallOne, 1)
        XCTAssertEqual(toolCallTwo, 2)
        XCTAssertEqual(toolCallThree, 3)
        do {
            _ = try await budget.consumeToolCall()
            XCTFail("Expected tool budget failure")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .toolCallBudgetExceeded(3))
        }
    }

    func testToolGateNeverExceedsFourConcurrentReads() async throws {
        let gate = ToolConcurrencyGate(limit: 20)
        let probe = ConcurrencyProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.withPermit {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }

        let gatePeak = await gate.peak
        let probePeak = await probe.peak
        XCTAssertEqual(gatePeak, 4)
        XCTAssertEqual(probePeak, 4)
    }

    func testCancellingQueuedToolRemovesWaiterAndDoesNotLeakPermit() async throws {
        let gate = ToolConcurrencyGate(limit: 1)
        let entered = TestSignal()
        let releaseFirst = TestSignal()
        let probe = ConcurrencyProbe()

        let first = Task {
            try await gate.withPermit {
                await entered.signal()
                await releaseFirst.wait()
            }
        }
        await entered.wait()

        let cancelled = Task {
            try await gate.withPermit {
                await probe.begin()
                await probe.end()
            }
        }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        cancelled.cancel()

        do {
            try await cancelled.value
            XCTFail("Expected the queued tool to be cancelled")
        } catch is CancellationError {
            // Expected: the queued operation never acquired the permit.
        }
        let remainingWaiters = await gate.waitingCount
        XCTAssertEqual(remainingWaiters, 0)

        await releaseFirst.signal()
        try await first.value

        try await gate.withPermit {
            await probe.begin()
            await probe.end()
        }
        let probePeak = await probe.peak
        XCTAssertEqual(probePeak, 1)
    }

    func testContextCompressionUsesAllFourStagesInOrder() async throws {
        let large = String(repeating: "evidence ", count: 100)
        let items = [
            AgentContextItem(
                id: "one",
                kind: .toolResult,
                content: large,
                observationDigest: "same-digest",
                artifactID: "artifact:one",
                phase: "scout",
                phaseCompleted: true
            ),
            AgentContextItem(
                id: "duplicate",
                kind: .toolResult,
                content: large,
                observationDigest: "same-digest",
                artifactID: "artifact:two",
                phase: "scout",
                phaseCompleted: true
            ),
            AgentContextItem(
                id: "old-assistant",
                kind: .assistant,
                content: String(repeating: "old state ", count: 120),
                observationDigest: nil,
                artifactID: nil,
                phase: "graph",
                phaseCompleted: true
            ),
            AgentContextItem(
                id: "tail-one",
                kind: .user,
                content: String(repeating: "current ", count: 10),
                observationDigest: nil,
                artifactID: nil,
                phase: nil,
                phaseCompleted: false
            ),
            AgentContextItem(
                id: "tail-two",
                kind: .toolResult,
                content: String(repeating: "tail ", count: 10),
                observationDigest: "tail-digest",
                artifactID: nil,
                phase: "answer",
                phaseCompleted: false
            ),
        ]
        let summarizer = FakeContextSummarizer()
        let projection = try await AgentContextProjector(
            largeOutputThreshold: 64,
            protectedTailCount: 2
        ).project(items, targetTokens: 500, summarizer: summarizer)

        XCTAssertEqual(
            projection.appliedStages,
            [
                .duplicateObservationDeduplication,
                .largeOutputHandles,
                .completedPhaseFold,
                .modelSummary,
            ]
        )
        let summarizerCalls = await summarizer.callCount
        XCTAssertEqual(summarizerCalls, 1)
        XCTAssertTrue(projection.items.first?.content.contains("model-generated") == true)
        XCTAssertEqual(projection.items.suffix(2).map(\.id), ["tail-one", "tail-two"])
        XCTAssertLessThanOrEqual(projection.estimatedTokens, projection.targetTokens)
    }

    func testRedactorNeverKeepsSecretsPathsBodiesOrNotes() {
        let redacted = AgentRedactor.metadata([
            "apiKey": "top-secret",
            "filePath": "/private/book.pdf",
            "body": "source text",
            "note": "personal note",
            "tool": "readFragment",
        ])

        XCTAssertEqual(redacted["apiKey"], "<redacted>")
        XCTAssertEqual(redacted["filePath"], "<redacted>")
        XCTAssertEqual(redacted["body"], "<redacted>")
        XCTAssertEqual(redacted["note"], "<redacted>")
        XCTAssertEqual(redacted["tool"], "readFragment")
    }

    func testContextProjectionFailsClosedWhenProtectedTailExceedsBudget() async throws {
        let tail = AgentContextItem(
            id: "oversized-current-turn",
            kind: .user,
            content: String(repeating: "current evidence ", count: 100),
            observationDigest: nil,
            artifactID: nil,
            phase: nil,
            phaseCompleted: false
        )

        do {
            _ = try await AgentContextProjector(protectedTailCount: 1).project(
                [tail],
                targetTokens: 20,
                summarizer: FakeContextSummarizer()
            )
            XCTFail("The host must never send a prompt above its hard budget")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .contextBudgetExceeded(20))
        }
    }

    func testOversizedModelSummaryIsDeterministicallyBounded() async throws {
        let items = [
            AgentContextItem(
                id: "old",
                kind: .assistant,
                content: String(repeating: "historical state ", count: 200),
                observationDigest: nil,
                artifactID: nil,
                phase: "old",
                phaseCompleted: false
            ),
            AgentContextItem(
                id: "tail",
                kind: .user,
                content: "current question",
                observationDigest: nil,
                artifactID: nil,
                phase: nil,
                phaseCompleted: false
            ),
        ]
        let projection = try await AgentContextProjector(protectedTailCount: 1).project(
            items,
            targetTokens: 300,
            summarizer: OversizedContextSummarizer()
        )

        XCTAssertTrue(projection.appliedStages.contains(.modelSummary))
        XCTAssertLessThanOrEqual(projection.estimatedTokens, 300)
        XCTAssertLessThanOrEqual(projection.items.first?.content.utf8.count ?? .max, 1)
    }

    func testAdversarialASCIIAndCodeUseConservativeByteUpperBound() async throws {
        let payload = String(repeating: "A", count: 512)
            + String(repeating: "{\"x\":1234567890}\n", count: 64)
        let item = AgentContextItem(
            id: "adversarial-code",
            kind: .toolResult,
            content: payload,
            observationDigest: nil,
            artifactID: nil,
            phase: "tool",
            phaseCompleted: false
        )
        XCTAssertGreaterThanOrEqual(item.estimatedTokens, payload.utf8.count)

        do {
            _ = try await AgentContextProjector(protectedTailCount: 1).project(
                [item],
                targetTokens: payload.utf8.count - 1
            )
            XCTFail("ASCII and code-heavy prompts must not be discounted by bytes/4")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .contextBudgetExceeded(payload.utf8.count - 1)
            )
        }
    }

    func testBaseModelSummarizerChunksEveryModelInputUnderHardBudget() async throws {
        let model = RecordingSummaryLanguageModel()
        let clock = AgentGenerationClock()
        let generation = await clock.begin()
        let inputBudget = 2_048
        let summary = try await BaseModelTranscriptSummarizer(
            model: model,
            budget: AgentRunBudget(limits: AgentRuntimeLimits(maxModelRounds: 64)),
            clock: clock,
            generation: generation,
            inputTokenBudget: inputBudget
        ).summarize([
            AgentContextItem(
                id: "large-history",
                kind: .toolResult,
                content: String(repeating: "func f() { print(1234567890) }\n", count: 180),
                observationDigest: "digest",
                artifactID: nil,
                phase: "scout",
                phaseCompleted: true
            ),
        ], maximumTokens: 512)

        XCTAssertFalse(summary.isEmpty)
        let encodedInputSizes = await model.encodedInputSizes()
        XCTAssertGreaterThan(encodedInputSizes.count, 1)
        XCTAssertTrue(encodedInputSizes.allSatisfy { $0 + 256 <= inputBudget })
    }

    func testBaseModelSummarizerRejectsProviderThatIgnoresOutputLimit() async throws {
        let model = UncooperativeOversizedLanguageModel()
        let clock = AgentGenerationClock()
        let generation = await clock.begin()

        do {
            _ = try await BaseModelTranscriptSummarizer(
                model: model,
                budget: AgentRunBudget(limits: AgentRuntimeLimits(maxModelRounds: 4)),
                clock: clock,
                generation: generation,
                limits: AgentRuntimeLimits(
                    maxModelRounds: 4,
                    maxResponseTokens: 32,
                    maxResponseBytes: 64
                ),
                inputTokenBudget: 2_048
            ).summarize([
                AgentContextItem(
                    id: "old",
                    kind: .assistant,
                    content: "history",
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "old",
                    phaseCompleted: true
                ),
            ], maximumTokens: 32)
            XCTFail("An uncooperative Provider must not bypass the host byte ceiling")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .responseBudgetExceeded(32))
        }
        let limits = await model.maximumResponseTokens()
        XCTAssertEqual(limits, [32])
    }

    func testUTF8BoundsNeverExpandTruncatedMultibyteScalar() {
        XCTAssertEqual(AgentUTF8.bounded("😀", maximumBytes: 1).utf8.count, 0)
        XCTAssertEqual(AgentUTF8.bounded("A😀", maximumBytes: 4), "A")
        XCTAssertEqual(
            AgentUTF8.chunks("中中", maximumBytes: 3).map(\.utf8.count),
            [3, 3]
        )
        XCTAssertTrue(AgentUTF8.chunks("😀", maximumBytes: 1).isEmpty)
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }
}

private actor FakeContextSummarizer: AgentContextSummarizer {
    private(set) var callCount = 0

    func summarize(_ items: [AgentContextItem], maximumTokens: Int) -> String {
        callCount += 1
        return "model-generated structured summary for \(items.count) items"
    }
}

private struct OversizedContextSummarizer: AgentContextSummarizer {
    func summarize(_ items: [AgentContextItem], maximumTokens: Int) -> String {
        String(repeating: "unbounded-summary ", count: 10_000)
    }
}

private final class RecordingSummaryLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let recorder = SummaryInputRecorder()

    func encodedInputSizes() async -> [Int] { await recorder.values }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let size = try encoder.encode(transcript).count
        await recorder.append(size)
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(Transcript.TextSegment(content: "bounded summary"))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class UncooperativeOversizedLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let state = ResponseOptionRecorder()

    func supports(locale: Locale) -> Bool { true }

    func maximumResponseTokens() async -> [Int?] { await state.values }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        await state.append(options?.maximumResponseTokens)
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: String(repeating: "x", count: 1_024)))]
        ))
    }


    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ResponseOptionRecorder {
    private(set) var values: [Int?] = []

    func append(_ value: Int?) {
        values.append(value)
    }
}

private actor SummaryInputRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private actor TestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signalled else { return }
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
