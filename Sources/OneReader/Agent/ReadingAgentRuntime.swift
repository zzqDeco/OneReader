import Foundation

struct AgentDriverContext: Sendable {
    let profile: ProviderProfile
    let secret: String?
    let database: LibraryDatabase
    let runID: String
    let generation: Int
    let limits: AgentRuntimeLimits
    let clock: AgentGenerationClock
    let budget: AgentRunBudget
    let recorder: AgentEventRecorder
}

protocol ReadingAgentDriverFactory: Sendable {
    func makeDriver(context: AgentDriverContext) throws -> any ReadingAgentModelDriver
}

struct DefaultReadingAgentDriverFactory: ReadingAgentDriverFactory {
    let languageModelFactory: any ProviderLanguageModelFactory

    init(
        languageModelFactory: any ProviderLanguageModelFactory = DefaultProviderLanguageModelFactory()
    ) {
        self.languageModelFactory = languageModelFactory
    }

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        SwiftAgentModelDriver(
            profile: context.profile,
            secret: context.secret,
            database: context.database,
            runID: context.runID,
            generation: context.generation,
            limits: context.limits,
            clock: context.clock,
            budget: context.budget,
            recorder: context.recorder,
            factory: languageModelFactory
        )
    }
}

struct AgentRunHandle: Sendable {
    let runID: String
    let events: AsyncThrowingStream<AgentEvent, Error>
}

struct SourceRevisionRefreshLease: Hashable, Sendable {
    let id: String
    let sourceID: String
    let spaceIDs: Set<String>
}

actor SourceRevisionBarrier {
    private var leases: [String: Set<String>] = [:]
    private var activeLeaseCounts: [String: Int] = [:]

    func acquire(sourceID: String, spaceIDs: [String]) -> SourceRevisionRefreshLease {
        let lease = SourceRevisionRefreshLease(
            id: UUID().uuidString.lowercased(),
            sourceID: sourceID,
            spaceIDs: Set(spaceIDs)
        )
        leases[lease.id] = lease.spaceIDs
        for spaceID in lease.spaceIDs {
            activeLeaseCounts[spaceID, default: 0] += 1
        }
        return lease
    }

    func release(_ lease: SourceRevisionRefreshLease) {
        guard leases.removeValue(forKey: lease.id) == lease.spaceIDs else { return }
        for spaceID in lease.spaceIDs {
            let remaining = (activeLeaseCounts[spaceID] ?? 1) - 1
            if remaining > 0 {
                activeLeaseCounts[spaceID] = remaining
            } else {
                activeLeaseCounts.removeValue(forKey: spaceID)
            }
        }
    }

    func isBlocked(spaceID: String) -> Bool {
        (activeLeaseCounts[spaceID] ?? 0) > 0
    }

    func performIfUnblocked<T: Sendable>(
        spaceID: String,
        operation: @Sendable () throws -> T
    ) throws -> T {
        guard (activeLeaseCounts[spaceID] ?? 0) == 0 else {
            throw ReadingAgentError.runNotCurrent
        }
        return try operation()
    }
}

protocol AgentCommitInterlock: Sendable {
    func beforeFinalCommit(runID: String) async
}

protocol AgentProviderBindingInterlock: Sendable {
    func beforeProviderBindingCheck(runID: String) async
}

protocol AgentSessionCancellationInterlock: Sendable {
    func afterClockInvalidation() async
}

protocol AgentSessionStartInterlock: Sendable {
    func afterRunPersisted(runID: String) async
}

struct ReadingTurnLoop: Sendable {
    let database: LibraryDatabase
    let toolHost: ReadingToolHost
    let validator: AgentOutputValidator
    let secretStore: any ProviderSecretStore
    let driverFactory: any ReadingAgentDriverFactory
    let limits: AgentRuntimeLimits
    let commitInterlock: (any AgentCommitInterlock)?
    let providerBindingInterlock: (any AgentProviderBindingInterlock)?

    func run(
        run: AgentRun,
        request: AgentRunRequest,
        profile: ProviderProfile?,
        generation: Int,
        clock: AgentGenerationClock,
        recorder: AgentEventRecorder
    ) async {
        do {
            try await clock.check(generation)
            try database.markAgentRunRunningCAS(
                id: run.id,
                spaceID: request.spaceID,
                generation: generation
            )
            try await recorder.emit(
                .phase,
                phase: "session",
                message: "Reading Agent Run 已开始。",
                metadata: ["task": request.task.rawValue]
            )

            await providerBindingInterlock?.beforeProviderBindingCheck(runID: run.id)
            guard let profile else { throw ReadingAgentError.noProvider }
            try ProviderPolicy.validateProfile(profile)
            guard let destinationIdentity = run.providerDestinationIdentity,
                  let revisionIdentity = run.providerRevisionIdentity else {
                throw ReadingAgentError.runNotCurrent
            }
            try database.requireProviderBindingCurrent(
                runID: run.id,
                spaceID: request.spaceID,
                profileID: profile.id,
                destinationIdentity: destinationIdentity,
                revisionIdentity: revisionIdentity
            )
            if try ProviderPolicy.requiresRemoteDisclosure(profile),
               try !database.hasAcknowledgedRemoteDisclosure(
                    spaceID: request.spaceID,
                    profileID: profile.id,
                    destinationIdentity: destinationIdentity
               ) {
                guard let event = try database.transitionAgentRunIfActive(
                    runID: run.id,
                    generation: generation,
                    allowedStates: [.running],
                    finalState: .waitingForUser,
                    errorCategory: "disclosure-required",
                    kind: .waitingForUser,
                    phase: "privacy",
                    message: "远程 Provider 首次读取该 Reading Space 前需要确认数据外发说明。"
                ) else { throw ReadingAgentError.runNotCurrent }
                try await recorder.publishPersisted(event)
                await recorder.finish()
                return
            }

            let secret: String?
            if profile.kind.requiresSecret {
                guard let reference = profile.keychainReference,
                      let value = try await secretStore.secret(for: reference) else {
                    throw ReadingAgentError.secretMissing
                }
                secret = value
            } else {
                secret = nil
            }

            let budget = AgentRunBudget(limits: limits)
            let gate = ToolConcurrencyGate(limit: limits.maxConcurrentTools)
            let runtime = ReadingToolRuntime(
                host: toolHost,
                request: request,
                runID: run.id,
                generation: generation,
                limits: limits,
                clock: clock,
                budget: budget,
                gate: gate,
                recorder: recorder
            )
            let driver = try driverFactory.makeDriver(context: AgentDriverContext(
                profile: profile,
                secret: secret,
                database: database,
                runID: run.id,
                generation: generation,
                limits: limits,
                clock: clock,
                budget: budget,
                recorder: recorder
            ))
            let requestData = try Self.encoder.encode(request)
            try await recorder.appendTranscript(role: .user, content: requestData)

            var correction: String?
            while true {
                try Task.checkCancellation()
                try await clock.check(generation)
                let prior = try database.fetchAgentSession(spaceID: request.spaceID)?.transcriptJSON
                let result: AgentModelResult
                do {
                    result = try await driver.generate(
                        AgentModelRequest(
                            runID: run.id,
                            generation: generation,
                            request: request,
                            correction: correction
                        ),
                        runtime: runtime,
                        previousTranscript: prior
                    )
                } catch let error as ReadingAgentError {
                    switch error {
                    case .invalidStructuredOutput:
                        correction = AgentRedactor.category(for: error)
                        try await recorder.emit(
                            .validation,
                            phase: "validate",
                            message: "结构化输出未通过 schema，已要求模型修正。",
                            metadata: ["result": correction ?? "invalid-output"]
                        )
                        continue
                    default:
                        throw error
                    }
                }

                try await clock.check(generation)
                let disposition: AgentCommitDisposition
                do {
                    disposition = try await validator.validate(
                        result.output,
                        request: request
                    )
                } catch let error as ReadingAgentError {
                    if case .validationRejected = error {
                        correction = AgentRedactor.category(for: error)
                        try await recorder.emit(
                            .validation,
                            phase: "validate",
                            message: "模型候选未通过宿主验证，已要求基于当前证据修正。",
                            metadata: ["result": correction ?? "validation-rejected"]
                        )
                        continue
                    }
                    throw error
                }
                try await clock.check(generation)
                try await finish(
                    disposition: disposition,
                    output: result.output,
                    run: run,
                    request: request,
                    budget: budget,
                    modelUsage: result.usage,
                    recorder: recorder
                )
                return
            }
        } catch is CancellationError {
            if let event = try? database.transitionAgentRunIfActive(
                runID: run.id,
                generation: generation,
                allowedStates: [.queued, .running, .waitingForUser],
                finalState: .cancelled,
                errorCategory: "cancelled",
                outputDisposition: "cancelled",
                kind: .cancelled,
                phase: "session",
                message: "Reading Agent Run 已取消。"
            ) {
                try? await recorder.publishPersisted(event)
            }
            await recorder.finish()
        } catch {
            let category = AgentRedactor.category(for: error)
            let state: AgentRunState = category == "stale-generation" ? .cancelled : .failed
            let transitionedEvent = try? database.transitionAgentRunIfActive(
                runID: run.id,
                generation: generation,
                allowedStates: [.queued, .running, .waitingForUser],
                finalState: state,
                errorCategory: category,
                outputDisposition: state == .cancelled ? "cancelled" : "failed",
                kind: state == .cancelled ? .cancelled : .failed,
                phase: "session",
                message: state == .cancelled
                    ? "Reading Agent Run 已被更新的任务取代。"
                    : "Reading Agent Run 失败，基础阅读不受影响。"
            )
            if let event = transitionedEvent {
                try? await recorder.publishPersisted(event)
            }
            let durableState = try? database.agentRunState(runID: run.id)
            let durableCancellationWon = durableState == .cancelled
                || durableState == .interrupted
            if state == .cancelled || durableCancellationWon {
                await recorder.finish()
            } else {
                await recorder.finish(throwing: AgentRedactor.publicError(for: error))
            }
        }
    }

    private func finish(
        disposition: AgentCommitDisposition,
        output: AgentStructuredOutput,
        run: AgentRun,
        request: AgentRunRequest,
        budget: AgentRunBudget,
        modelUsage: AgentTokenUsage?,
        recorder: AgentEventRecorder
    ) async throws {
        let usage = await budget.usage()
        var usageMetadata = [
            "modelRounds": String(usage.modelRounds),
            "toolCalls": String(usage.toolCalls),
        ]
        if let modelUsage {
            usageMetadata["inputTokens"] = String(modelUsage.inputTokens)
            usageMetadata["outputTokens"] = String(modelUsage.outputTokens)
            usageMetadata["durationMilliseconds"] = String(
                modelUsage.durationMilliseconds
            )
            usageMetadata["usageMeasurement"] = "host-conservative-upper-bound"
        }
        await commitInterlock?.beforeFinalCommit(runID: run.id)
        try Task.checkCancellation()
        switch disposition {
        case let .waitingForUser(reason, candidate):
            let outputRecord = PersistedAgentOutput(
                runID: run.id,
                kind: Self.outputKind(candidate),
                output: candidate,
                disposition: "waitingForUser",
                createdAt: .now
            )
            let event = try await recorder.preparePersistedEvent(
                .waitingForUser,
                phase: "validate",
                message: "候选方案需要用户确认，当前基础适配器和冻结路径保持不变。",
                metadata: usageMetadata.merging(["reason": reason]) { current, _ in current }
            )
            try database.finalizeAgentRun(
                runID: run.id,
                spaceID: request.spaceID,
                generation: run.generation,
                manifest: request.snapshotManifest,
                output: outputRecord,
                finalState: .waitingForUser,
                errorCategory: reason,
                mutation: nil,
                event: event
            )
            try await recorder.publishPersisted(event)
            await recorder.finish()

        case let .committed(kind, identifier, mutation):
            let outputRecord = PersistedAgentOutput(
                runID: run.id,
                kind: kind,
                output: output,
                disposition: "committed",
                createdAt: .now
            )
            let event = try await recorder.preparePersistedEvent(
                .completed,
                phase: "commit",
                message: "宿主验证通过并已事务提交：\(kind)。",
                metadata: usageMetadata.merging(["identifier": identifier]) { current, _ in current }
            )
            try database.finalizeAgentRun(
                runID: run.id,
                spaceID: request.spaceID,
                generation: run.generation,
                manifest: request.snapshotManifest,
                output: outputRecord,
                finalState: .completed,
                errorCategory: nil,
                mutation: mutation,
                event: event
            )
            try await recorder.publishPersisted(event)
            await recorder.finish()

        case let .acceptedWithoutCommit(kind):
            let outputRecord = PersistedAgentOutput(
                runID: run.id,
                kind: kind,
                output: output,
                disposition: "accepted",
                createdAt: .now
            )
            let event = try await recorder.preparePersistedEvent(
                .completed,
                phase: "complete",
                message: "带证据的 Agent 结果已通过宿主验证。",
                metadata: usageMetadata.merging(["kind": kind]) { current, _ in current }
            )
            try database.finalizeAgentRun(
                runID: run.id,
                spaceID: request.spaceID,
                generation: run.generation,
                manifest: request.snapshotManifest,
                output: outputRecord,
                finalState: .completed,
                errorCategory: nil,
                mutation: nil,
                event: event
            )
            try await recorder.publishPersisted(event)
            await recorder.finish()
        }
    }

    private static func outputKind(_ output: AgentStructuredOutput) -> String {
        switch output {
        case .adapterPlan: "adapterPlan"
        case .graphPatch: "graphPatch"
        case .readingPlan: "readingPlan"
        case .evidenceAnswer: "evidenceAnswer"
        case .scoutingSummary: "scoutingSummary"
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

actor ReadingAgentSession {
    let spaceID: String
    private let database: LibraryDatabase
    private let clock: AgentGenerationClock
    private let loop: ReadingTurnLoop
    private let sourceRevisionBarrier: SourceRevisionBarrier
    private let cancellationInterlock: (any AgentSessionCancellationInterlock)?
    private let startInterlock: (any AgentSessionStartInterlock)?
    private var activeTask: Task<Void, Never>?
    private var activeRunID: String?
    private var activeGeneration: Int?
    private var activeRecorder: AgentEventRecorder?
    private var pendingStartID: UUID?

    init(
        spaceID: String,
        database: LibraryDatabase,
        toolHost: ReadingToolHost,
        validator: AgentOutputValidator,
        secretStore: any ProviderSecretStore,
        driverFactory: any ReadingAgentDriverFactory = DefaultReadingAgentDriverFactory(),
        limits: AgentRuntimeLimits = .standard,
        commitInterlock: (any AgentCommitInterlock)? = nil,
        providerBindingInterlock: (any AgentProviderBindingInterlock)? = nil,
        cancellationInterlock: (any AgentSessionCancellationInterlock)? = nil,
        startInterlock: (any AgentSessionStartInterlock)? = nil,
        sourceRevisionBarrier: SourceRevisionBarrier = SourceRevisionBarrier()
    ) throws {
        self.spaceID = spaceID
        self.database = database
        self.sourceRevisionBarrier = sourceRevisionBarrier
        self.cancellationInterlock = cancellationInterlock
        self.startInterlock = startInterlock
        let generation = try database.fetchAgentSession(spaceID: spaceID)?.generation ?? 0
        clock = AgentGenerationClock(initialGeneration: generation)
        loop = ReadingTurnLoop(
            database: database,
            toolHost: toolHost,
            validator: validator,
            secretStore: secretStore,
            driverFactory: driverFactory,
            limits: limits,
            commitInterlock: commitInterlock,
            providerBindingInterlock: providerBindingInterlock
        )
    }

    func start(_ request: AgentRunRequest) async throws -> AgentRunHandle {
        try await start(request, resumedFrom: nil)
    }

    func resume(runID: String) async throws -> AgentRunHandle {
        guard let previous = try database.fetchAgentRuns(spaceID: spaceID)
            .first(where: { $0.id == runID }),
              let request = try database.request(forRunID: runID) else {
            throw ReadingAgentError.interrupted
        }
        if let output = try database.agentOutput(runID: runID),
           output.disposition == "waitingForUser",
           case .adapterPlan = output.output {
            throw ReadingAgentError.interrupted
        }
        guard previous.state == .interrupted
                || (previous.state == .waitingForUser
                    && previous.errorCategory == "disclosure-required") else {
            throw ReadingAgentError.interrupted
        }
        return try await start(request, resumedFrom: runID)
    }

    @discardableResult
    func confirmAdapterCandidate(runID: String) async throws -> AdapterPlan {
        let currentGeneration = await clock.current()
        guard let run = try database.fetchAgentRuns(spaceID: spaceID)
            .first(where: { $0.id == runID }),
              (run.state == .waitingForUser || run.state == .interrupted),
              run.generation == currentGeneration,
              let request = try database.request(forRunID: runID),
              let persisted = try database.agentOutput(runID: runID),
              persisted.disposition == "waitingForUser",
              case .adapterPlan(let candidate) = persisted.output else {
            throw ReadingAgentError.validationRejected("adapter-candidate-not-confirmable")
        }
        let confirmed = try await loop.validator.confirmAdapterPlan(
            candidate,
            request: request
        )
        let outputRecord = PersistedAgentOutput(
            runID: runID,
            kind: "adapterPlan",
            output: .adapterPlan(confirmed),
            disposition: "userConfirmed",
            createdAt: .now
        )
        let event = try makePostRunEvent(
            runID: runID,
            kind: .completed,
            phase: "confirm",
            message: "用户确认了低置信度适配器候选；当前 Snapshot 已重新验证。"
        )
        try database.finalizeAgentRun(
            runID: runID,
            spaceID: spaceID,
            generation: run.generation,
            manifest: request.snapshotManifest,
            output: outputRecord,
            finalState: .completed,
            errorCategory: nil,
            mutation: .adapterPlan(confirmed),
            event: event,
            allowedRunStates: [.waitingForUser, .interrupted]
        )
        return confirmed
    }

    func dismissAdapterCandidate(runID: String) throws {
        guard let run = try database.fetchAgentRuns(spaceID: spaceID)
            .first(where: { $0.id == runID }),
              (run.state == .waitingForUser || run.state == .interrupted),
              let output = try database.agentOutput(runID: runID),
              output.disposition == "waitingForUser",
              case .adapterPlan = output.output else {
            throw ReadingAgentError.validationRejected("adapter-candidate-not-dismissible")
        }
        guard try database.transitionAgentRunIfActive(
            runID: runID,
            generation: run.generation,
            allowedStates: [.waitingForUser, .interrupted],
            finalState: .cancelled,
            errorCategory: "user-dismissed",
            outputDisposition: "userDismissed",
            kind: .cancelled,
            phase: "confirm",
            message: "用户保留了确定性基础适配器方案。"
        ) != nil else { throw ReadingAgentError.runNotCurrent }
    }

    func cancel() async {
        // Cancel also invalidates a Run that is being prepared but has not yet
        // installed its task into the session actor.
        pendingStartID = nil
        let runID = activeRunID
        let generation = activeGeneration
        let recorder = activeRecorder
        let task = activeTask
        let event: AgentEvent?
        if let runID, let generation {
            event = try? database.transitionAgentRunIfActive(
                runID: runID,
                generation: generation,
                allowedStates: [.queued, .running, .waitingForUser],
                finalState: .cancelled,
                errorCategory: "cancelled",
                outputDisposition: "cancelled",
                kind: .cancelled,
                phase: "session",
                message: "Reading Agent Run 已取消。"
            )
        } else {
            event = nil
        }
        // Persist terminal cancellation before signalling the in-flight task.
        // A non-cooperative Provider that returns concurrently is then ordered
        // against the audit transaction by SQLite, with exactly one winner.
        task?.cancel()
        if let generation {
            _ = await clock.invalidate(ifCurrent: generation)
        }
        await cancellationInterlock?.afterClockInvalidation()
        if let event {
            try? await recorder?.publishPersisted(event)
            await recorder?.finish()
        }
    }

    func invalidateForSourceRevision() async {
        await cancel()
    }

    func completeSourceRevisionRefresh(durableGeneration: Int) async {
        await clock.synchronize(to: durableGeneration)
    }

    func abortSourceRevisionRefresh() async {
        if let durableGeneration = try? database.fetchAgentSession(spaceID: spaceID)?.generation {
            await clock.synchronize(to: durableGeneration)
        }
    }

    private func start(
        _ requested: AgentRunRequest,
        resumedFrom: String?
    ) async throws -> AgentRunHandle {
        try Task.checkCancellation()
        guard requested.spaceID == spaceID else {
            throw ReadingAgentError.validationRejected("session-space-mismatch")
        }
        try validateRequestFields(requested)
        let startID = UUID()
        pendingStartID = startID
        defer {
            if pendingStartID == startID {
                pendingStartID = nil
            }
        }
        let isSourceRefreshBlocked = await sourceRevisionBarrier.isBlocked(
            spaceID: spaceID
        )
        try Task.checkCancellation()
        try requirePendingStart(startID)
        guard !isSourceRefreshBlocked else {
            throw ReadingAgentError.runNotCurrent
        }
        let manifest = try database.currentSnapshotManifest(spaceID: spaceID)
        guard !manifest.isEmpty,
              requested.expectedSnapshotIDs.isEmpty
                || requested.expectedSnapshotIDs == Set(manifest.values) else {
            throw ReadingAgentError.validationRejected("snapshot-set-changed")
        }
        let request = AgentRunRequest(
            spaceID: requested.spaceID,
            task: requested.task,
            goal: requested.goal,
            question: requested.question,
            targetSourceID: requested.targetSourceID,
            targetSnapshotID: requested.targetSnapshotID,
            expectedSnapshotIDs: Set(manifest.values),
            snapshotManifest: manifest
        )
        if request.task == .routeAdapters {
            guard let targetSourceID = request.targetSourceID,
                  let targetSnapshotID = request.targetSnapshotID,
                  manifest[targetSourceID] == targetSnapshotID else {
                throw ReadingAgentError.validationRejected("adapter-route-target-not-current")
            }
        }
        await supersedeActiveRun()
        try Task.checkCancellation()
        try requirePendingStart(startID)
        let durableGeneration = try database.fetchAgentSession(spaceID: spaceID)?.generation ?? 0
        await clock.synchronize(to: durableGeneration)
        try Task.checkCancellation()
        try requirePendingStart(startID)
        let generation = await clock.begin()
        try Task.checkCancellation()
        try requirePendingStart(startID)
        let profile = try database.providerProfile(forSpaceID: spaceID)
        let destinationIdentity = try profile.map(ProviderPolicy.destinationIdentity)
        let revisionIdentity = try profile.map(ProviderPolicy.revisionIdentity)
        let run = AgentRun(
            id: UUID().uuidString.lowercased(),
            spaceID: spaceID,
            task: request.task,
            generation: generation,
            state: .queued,
            providerProfileID: profile?.id,
            providerDestinationIdentity: destinationIdentity,
            providerRevisionIdentity: revisionIdentity,
            createdAt: .now,
            startedAt: nil,
            finishedAt: nil,
            errorCategory: nil
        )
        let queuedEvent = try await sourceRevisionBarrier.performIfUnblocked(spaceID: spaceID) {
            try database.beginAgentRun(run, request: request, resumedFrom: resumedFrom)
        }
        var recorder: AgentEventRecorder?
        do {
            await startInterlock?.afterRunPersisted(runID: run.id)
            try Task.checkCancellation()
            try requirePendingStart(startID)

            let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
            let runRecorder = AgentEventRecorder(
                database: database,
                runID: run.id,
                continuation: pair.continuation
            )
            recorder = runRecorder
            try await runRecorder.publishPersisted(queuedEvent)
            try Task.checkCancellation()
            try requirePendingStart(startID)

            let loop = self.loop
            let clock = self.clock
            activeRunID = run.id
            activeGeneration = generation
            activeRecorder = runRecorder
            activeTask = Task {
                await loop.run(
                    run: run,
                    request: request,
                    profile: profile,
                    generation: generation,
                    clock: clock,
                    recorder: runRecorder
                )
                self.clearActiveRun(ifMatching: run.id)
            }
            pair.continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    Task { await self.cancelIfActive(runID: run.id) }
                }
            }
            return AgentRunHandle(runID: run.id, events: pair.stream)
        } catch {
            terminalizePersistedStart(run, error: error)
            await recorder?.finish()
            throw error
        }
    }

    private func cancelIfActive(runID: String) async {
        guard activeRunID == runID,
              let generation = activeGeneration else { return }
        let task = activeTask
        let recorder = activeRecorder
        let event = try? database.transitionAgentRunIfActive(
            runID: runID,
            generation: generation,
            allowedStates: [.queued, .running, .waitingForUser],
            finalState: .cancelled,
            errorCategory: "consumer-terminated",
            outputDisposition: "cancelled",
            kind: .cancelled,
            phase: "session",
            message: "Reading Agent Run 的阅读界面已离开，当前 Run 已取消。"
        )
        task?.cancel()
        _ = await clock.invalidate(ifCurrent: generation)
        if let event {
            try? await recorder?.publishPersisted(event)
            await recorder?.finish()
        }
    }

    private func makePostRunEvent(
        runID: String,
        kind: AgentEventKind,
        phase: String,
        message: String
    ) throws -> AgentEvent {
        let sequence = (try database.fetchAgentEvents(runID: runID).last?.sequence ?? -1) + 1
        return AgentEvent(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            sequence: sequence,
            kind: kind,
            phase: phase,
            message: message,
            metadata: [:],
            createdAt: .now
        )
    }

    private func supersedeActiveRun() async {
        guard let runID = activeRunID,
              let generation = activeGeneration else { return }
        let task = activeTask
        let recorder = activeRecorder
        let event = try? database.transitionAgentRunIfActive(
            runID: runID,
            generation: generation,
            allowedStates: [.queued, .running, .waitingForUser],
            finalState: .cancelled,
            errorCategory: "superseded",
            outputDisposition: "superseded",
            kind: .cancelled,
            phase: "session",
            message: "Reading Agent Run 已被新的任务取代。"
        )
        task?.cancel()
        if let event {
            try? await recorder?.publishPersisted(event)
            await recorder?.finish()
        }
    }

    private func requirePendingStart(_ startID: UUID) throws {
        guard pendingStartID == startID else {
            throw ReadingAgentError.runNotCurrent
        }
    }

    private func terminalizePersistedStart(_ run: AgentRun, error: Error) {
        let isCallerCancellation = error is CancellationError
        let isSuperseded = (error as? ReadingAgentError) == .runNotCurrent
        let finalState: AgentRunState = isCallerCancellation || isSuperseded
            ? .cancelled
            : .failed
        let category: String
        let message: String
        if isCallerCancellation {
            category = "cancelled-before-install"
            message = "Reading Agent Run 在启动完成前被调用方取消。"
        } else if isSuperseded {
            category = "superseded-before-install"
            message = "Reading Agent Run 在启动完成前被新的操作取代。"
        } else {
            category = "startup-\(AgentRedactor.category(for: error))"
            message = "Reading Agent Run 未能完成启动，基础阅读不受影响。"
        }
        _ = try? database.transitionAgentRunIfActive(
            runID: run.id,
            generation: run.generation,
            allowedStates: [.queued, .running, .waitingForUser],
            finalState: finalState,
            errorCategory: category,
            outputDisposition: finalState == .cancelled ? "cancelled" : "failed",
            kind: finalState == .cancelled ? .cancelled : .failed,
            phase: "session",
            message: message
        )
    }

    private func clearActiveRun(ifMatching runID: String) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        activeGeneration = nil
        activeRecorder = nil
        activeTask = nil
    }

    private func validateRequestFields(_ request: AgentRunRequest) throws {
        guard (request.goal?.count ?? 0) <= 16_384,
              (request.question?.count ?? 0) <= 16_384 else {
            throw ReadingAgentError.validationRejected("request-too-large")
        }
        if request.task == .routeAdapters {
            guard request.targetSourceID?.isEmpty == false,
                  request.targetSnapshotID?.isEmpty == false else {
                throw ReadingAgentError.validationRejected("adapter-route-target-required")
            }
        } else if request.targetSourceID != nil || request.targetSnapshotID != nil {
            throw ReadingAgentError.validationRejected("adapter-route-target-unexpected")
        }
    }
}

actor ReadingAgentRuntime {
    private let database: LibraryDatabase
    private let toolHost: ReadingToolHost
    private let validator: AgentOutputValidator
    private let secretStore: any ProviderSecretStore
    private let driverFactory: any ReadingAgentDriverFactory
    private let limits: AgentRuntimeLimits
    private let commitInterlock: (any AgentCommitInterlock)?
    private let providerBindingInterlock: (any AgentProviderBindingInterlock)?
    private let sourceRevisionBarrier: SourceRevisionBarrier
    private var sessions: [String: ReadingAgentSession] = [:]

    init(
        database: LibraryDatabase,
        toolHost: ReadingToolHost,
        validator: AgentOutputValidator,
        secretStore: any ProviderSecretStore = KeychainProviderSecretStore(),
        driverFactory: any ReadingAgentDriverFactory = DefaultReadingAgentDriverFactory(),
        limits: AgentRuntimeLimits = .standard,
        commitInterlock: (any AgentCommitInterlock)? = nil,
        providerBindingInterlock: (any AgentProviderBindingInterlock)? = nil,
        sourceRevisionBarrier: SourceRevisionBarrier = SourceRevisionBarrier()
    ) {
        self.database = database
        self.toolHost = toolHost
        self.validator = validator
        self.secretStore = secretStore
        self.driverFactory = driverFactory
        self.limits = limits
        self.commitInterlock = commitInterlock
        self.providerBindingInterlock = providerBindingInterlock
        self.sourceRevisionBarrier = sourceRevisionBarrier
    }

    func session(forSpaceID spaceID: String) async throws -> ReadingAgentSession {
        guard !(await sourceRevisionBarrier.isBlocked(spaceID: spaceID)) else {
            throw ReadingAgentError.runNotCurrent
        }
        if let session = sessions[spaceID] { return session }
        let session = try ReadingAgentSession(
            spaceID: spaceID,
            database: database,
            toolHost: toolHost,
            validator: validator,
            secretStore: secretStore,
            driverFactory: driverFactory,
            limits: limits,
            commitInterlock: commitInterlock,
            providerBindingInterlock: providerBindingInterlock,
            sourceRevisionBarrier: sourceRevisionBarrier
        )
        sessions[spaceID] = session
        return session
    }

    func beginSourceRevisionRefresh(
        sourceID: String
    ) async throws -> SourceRevisionRefreshLease {
        let spaceIDs = try database.spaceIDs(containing: sourceID)
        let lease = await sourceRevisionBarrier.acquire(
            sourceID: sourceID,
            spaceIDs: spaceIDs
        )
        for spaceID in spaceIDs {
            if let session = sessions[spaceID] {
                await session.invalidateForSourceRevision()
            }
        }
        return lease
    }

    func completeSourceRevisionRefresh(
        lease: SourceRevisionRefreshLease,
        generations: [String: Int]
    ) async {
        for spaceID in lease.spaceIDs {
            if let session = sessions[spaceID] {
                let generation = generations[spaceID]
                    ?? (try? database.fetchAgentSession(spaceID: spaceID)?.generation)
                    ?? 0
                await session.completeSourceRevisionRefresh(durableGeneration: generation)
            }
        }
        await sourceRevisionBarrier.release(lease)
    }

    func abortSourceRevisionRefresh(lease: SourceRevisionRefreshLease) async {
        for spaceID in lease.spaceIDs {
            if let session = sessions[spaceID] {
                await session.abortSourceRevisionRefresh()
            }
        }
        await sourceRevisionBarrier.release(lease)
    }

    func cancelSession(forSpaceID spaceID: String) async {
        guard let session = sessions[spaceID] else { return }
        await session.cancel()
    }
}
