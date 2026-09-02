import Foundation

actor AgentGenerationClock {
    private var generation: Int

    init(initialGeneration: Int = 0) {
        generation = initialGeneration
    }

    func begin() -> Int {
        generation += 1
        return generation
    }

    func invalidate() {
        generation += 1
    }

    @discardableResult
    func invalidate(ifCurrent candidate: Int) -> Bool {
        guard generation == candidate else { return false }
        generation += 1
        return true
    }

    func synchronize(to durableGeneration: Int) {
        generation = max(generation, durableGeneration)
    }

    func isCurrent(_ candidate: Int) -> Bool {
        candidate == generation
    }

    func check(_ candidate: Int) throws {
        guard candidate == generation else {
            throw ReadingAgentError.runNotCurrent
        }
    }

    func current() -> Int { generation }
}

actor AgentRunBudget {
    private let limits: AgentRuntimeLimits
    private(set) var modelRounds = 0
    private(set) var toolCalls = 0

    init(limits: AgentRuntimeLimits) {
        self.limits = limits
    }

    func consumeModelRound() throws -> Int {
        guard modelRounds < limits.maxModelRounds else {
            throw ReadingAgentError.modelRoundBudgetExceeded(limits.maxModelRounds)
        }
        modelRounds += 1
        return modelRounds
    }

    func consumeToolCall() throws -> Int {
        guard toolCalls < limits.maxToolCalls else {
            throw ReadingAgentError.toolCallBudgetExceeded(limits.maxToolCalls)
        }
        toolCalls += 1
        return toolCalls
    }

    func usage() -> (modelRounds: Int, toolCalls: Int) {
        (modelRounds, toolCalls)
    }
}

actor ToolConcurrencyGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private(set) var peak = 0

    var waitingCount: Int { waiters.count }

    init(limit: Int) {
        self.limit = min(max(1, limit), 4)
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            peak = max(peak, active)
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        precondition(active > 0, "ToolConcurrencyGate released without an active permit")
        if waiters.isEmpty {
            active -= 1
        } else {
            let waiter = waiters.removeFirst()
            // Ownership transfers directly to the resumed waiter, so `active`
            // must not briefly drop and expose the same permit twice.
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

actor AgentEventRecorder {
    private let database: LibraryDatabase
    private let runID: String
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private var eventSequence: Int
    private var isFinished = false

    init(
        database: LibraryDatabase,
        runID: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        initialEventSequence: Int = 0
    ) {
        self.database = database
        self.runID = runID
        self.continuation = continuation
        eventSequence = initialEventSequence
    }

    @discardableResult
    func emit(
        _ kind: AgentEventKind,
        phase: String,
        message: String,
        metadata: [String: String] = [:]
    ) throws -> AgentEvent {
        guard !isFinished else { throw ReadingAgentError.interrupted }
        let event = AgentEvent(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            sequence: eventSequence,
            kind: kind,
            phase: phase,
            message: message,
            metadata: AgentRedactor.metadata(metadata),
            createdAt: .now
        )
        try database.appendAgentEvent(event)
        eventSequence += 1
        continuation.yield(event)
        return event
    }

    func preparePersistedEvent(
        _ kind: AgentEventKind,
        phase: String,
        message: String,
        metadata: [String: String] = [:]
    ) throws -> AgentEvent {
        guard !isFinished else { throw ReadingAgentError.interrupted }
        return AgentEvent(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            sequence: eventSequence,
            kind: kind,
            phase: phase,
            message: message,
            metadata: AgentRedactor.metadata(metadata),
            createdAt: .now
        )
    }

    func publishPersisted(_ event: AgentEvent) throws {
        guard event.runID == runID else {
            throw ReadingAgentError.interrupted
        }
        if event.sequence < eventSequence {
            return
        }
        guard !isFinished else { throw ReadingAgentError.interrupted }
        try replayPersistedEvents(through: event.sequence)
        guard event.sequence < eventSequence else {
            throw ReadingAgentError.interrupted
        }
    }

    func appendTranscript(
        role: AgentTranscriptRole,
        disposition: AgentTranscriptDisposition = .complete,
        content: Data
    ) throws {
        guard !isFinished else { throw ReadingAgentError.interrupted }
        try database.appendTranscriptRecord(
            runID: runID,
            role: role,
            disposition: disposition,
            content: content,
            createdAt: .now
        )
    }

    func finish() {
        guard !isFinished else { return }
        do {
            try replayPersistedEvents()
        } catch {
            isFinished = true
            continuation.finish(throwing: error)
            return
        }
        isFinished = true
        continuation.finish()
    }

    func finish(throwing error: Error) {
        guard !isFinished else { return }
        do {
            try replayPersistedEvents()
        } catch {
            isFinished = true
            continuation.finish(throwing: error)
            return
        }
        isFinished = true
        continuation.finish(throwing: error)
    }

    private func replayPersistedEvents(through finalSequence: Int? = nil) throws {
        let pending = try database.fetchAgentEvents(runID: runID).filter { event in
            guard event.sequence >= eventSequence else { return false }
            return finalSequence.map { event.sequence <= $0 } ?? true
        }
        for event in pending {
            guard event.sequence == eventSequence else {
                throw ReadingAgentError.interrupted
            }
            eventSequence += 1
            continuation.yield(event)
        }
    }
}

struct AgentContextItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case instruction
        case user
        case assistant
        case toolCall
        case toolResult
        case phaseSummary
    }

    let id: String
    let kind: Kind
    let content: String
    let observationDigest: String?
    let artifactID: String?
    let phase: String?
    let phaseCompleted: Bool

    var estimatedTokens: Int {
        let idAndKind = id.utf8.count.addingReportingOverflow(
            kind.rawValue.utf8.count
        )
        let baseOverhead = idAndKind.overflow ? Int.max : idAndKind.partialValue
        let withStructure = baseOverhead.addingReportingOverflow(64)
        return AgentTokenCounter.conservativeUpperBound(
            content,
            structuralOverhead: withStructure.overflow ? .max : withStructure.partialValue
        )
    }
}

enum AgentTokenCounter {
    // The supported Provider tokenizers ultimately fall back to byte pieces.
    // Counting every UTF-8 byte as a token, plus explicit structure overhead,
    // is intentionally conservative and cannot undercount arbitrary code or
    // adversarial text the way a bytes/4 heuristic can.
    static func conservativeUpperBound(
        _ value: String,
        structuralOverhead: Int = 16
    ) -> Int {
        let result = value.utf8.count.addingReportingOverflow(
            max(0, structuralOverhead)
        )
        return max(1, result.overflow ? .max : result.partialValue)
    }
}

enum AgentUTF8 {
    static func bounded(_ value: String, maximumBytes: Int) -> String {
        let limit = max(0, maximumBytes)
        guard value.utf8.count > limit else { return value }
        var result = ""
        var used = 0
        for scalar in value.unicodeScalars {
            let byteCount = String(scalar).utf8.count
            guard used + byteCount <= limit else { break }
            result.unicodeScalars.append(scalar)
            used += byteCount
        }
        return result
    }

    static func chunks(_ value: String, maximumBytes: Int) -> [String] {
        let limit = max(1, maximumBytes)
        guard !value.isEmpty else { return [""] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for scalar in value.unicodeScalars {
            let byteCount = String(scalar).utf8.count
            guard byteCount <= limit else { continue }
            if !current.isEmpty, currentBytes + byteCount > limit {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.unicodeScalars.append(scalar)
            currentBytes += byteCount
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

enum ContextCompressionStage: String, Codable, CaseIterable, Sendable {
    case duplicateObservationDeduplication
    case largeOutputHandles
    case completedPhaseFold
    case modelSummary
}

struct AgentContextProjection: Codable, Hashable, Sendable {
    let items: [AgentContextItem]
    let appliedStages: [ContextCompressionStage]
    let estimatedTokens: Int
    let targetTokens: Int
}

protocol AgentContextSummarizer: Sendable {
    func summarize(_ items: [AgentContextItem], maximumTokens: Int) async throws -> String
}

struct AgentContextProjector: Sendable {
    let largeOutputThreshold: Int
    let protectedTailCount: Int

    init(largeOutputThreshold: Int = 65_536, protectedTailCount: Int = 8) {
        self.largeOutputThreshold = largeOutputThreshold
        self.protectedTailCount = max(1, protectedTailCount)
    }

    func project(
        _ original: [AgentContextItem],
        targetTokens: Int,
        summarizer: (any AgentContextSummarizer)? = nil
    ) async throws -> AgentContextProjection {
        let targetTokens = max(1, targetTokens)
        var items = original
        var stages: [ContextCompressionStage] = []

        var seenDigests = Set<String>()
        var didDeduplicate = false
        items = items.map { item in
            guard let digest = item.observationDigest else { return item }
            guard !seenDigests.insert(digest).inserted else { return item }
            didDeduplicate = true
            return replacing(
                item,
                content: "[Duplicate observation omitted; digest=\(digest)]"
            )
        }
        if didDeduplicate { stages.append(.duplicateObservationDeduplication) }

        if tokenCount(items) > targetTokens {
            var didReplaceLargeOutput = false
            items = items.map { item in
                guard item.kind == .toolResult,
                      item.content.utf8.count > largeOutputThreshold else { return item }
                didReplaceLargeOutput = true
                let digest = item.observationDigest
                    ?? AdapterUtilities.sha256(item.content)
                let handle = item.artifactID ?? "digest:\(digest)"
                return replacing(
                    item,
                    content: "[Large tool result available by handle \(handle); digest=\(digest)]"
                )
            }
            if didReplaceLargeOutput { stages.append(.largeOutputHandles) }
        }

        if tokenCount(items) > targetTokens {
            let split = max(0, items.count - protectedTailCount)
            let oldItems = Array(items[..<split])
            let tail = Array(items[split...])
            let completed = oldItems.filter(\.phaseCompleted)
            if !completed.isEmpty {
                let completedIDs = Set(completed.map(\.id))
                let retained = oldItems.filter { !completedIDs.contains($0.id) }
                let summary = completed.map { item in
                    "- \(item.phase ?? "phase"): \(item.kind.rawValue), digest=\(item.observationDigest ?? AdapterUtilities.sha256(item.content))"
                }.joined(separator: "\n")
                items = retained + [AgentContextItem(
                    id: "phase-fold:\(UUID().uuidString.lowercased())",
                    kind: .phaseSummary,
                    content: "Completed phase evidence:\n\(summary)",
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "completed",
                    phaseCompleted: true
                )] + tail
                stages.append(.completedPhaseFold)
            }
        }

        if tokenCount(items) > targetTokens, let summarizer {
            let split = max(0, items.count - protectedTailCount)
            let prefix = Array(items[..<split])
            let tail = Array(items[split...])
            if !prefix.isEmpty {
                let maximumSummaryTokens = max(1, targetTokens / 3)
                let summary = try await summarizer.summarize(
                    prefix,
                    maximumTokens: maximumSummaryTokens
                )
                items = [AgentContextItem(
                    id: "model-summary:\(UUID().uuidString.lowercased())",
                    kind: .phaseSummary,
                    content: AgentUTF8.bounded(
                        summary,
                        maximumBytes: max(1, maximumSummaryTokens - 128)
                    ),
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "compressed-history",
                    phaseCompleted: true
                )] + tail
                stages.append(.modelSummary)
            }
        }

        let estimatedTokens = tokenCount(items)
        guard estimatedTokens <= targetTokens else {
            throw ReadingAgentError.contextBudgetExceeded(targetTokens)
        }

        return AgentContextProjection(
            items: items,
            appliedStages: stages,
            estimatedTokens: estimatedTokens,
            targetTokens: targetTokens
        )
    }

    private func replacing(_ item: AgentContextItem, content: String) -> AgentContextItem {
        AgentContextItem(
            id: item.id,
            kind: item.kind,
            content: content,
            observationDigest: item.observationDigest,
            artifactID: item.artifactID,
            phase: item.phase,
            phaseCompleted: item.phaseCompleted
        )
    }

    private func tokenCount(_ items: [AgentContextItem]) -> Int {
        items.reduce(0) { $0 + $1.estimatedTokens }
    }

}
