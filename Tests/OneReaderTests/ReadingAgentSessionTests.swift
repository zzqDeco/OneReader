import Foundation
import GRDB
import OpenFoundationModels
import XCTest
@testable import OneReader

final class ReadingAgentSessionTests: XCTestCase {
    func testRouteAdapterRunRequiresCurrentExplicitSourceAndSnapshotTarget() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )

        do {
            _ = try await session.start(AgentRunRequest(
                spaceID: fixture.imported.space.id,
                task: .routeAdapters,
                expectedSnapshotIDs: [fixture.imported.snapshot.id]
            ))
            XCTFail("A route run without a target must be rejected before persistence")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .validationRejected("adapter-route-target-required")
            )
        }

        do {
            _ = try await session.start(AgentRunRequest(
                spaceID: fixture.imported.space.id,
                task: .routeAdapters,
                targetSourceID: "wrong-source",
                targetSnapshotID: fixture.imported.snapshot.id,
                expectedSnapshotIDs: [fixture.imported.snapshot.id]
            ))
            XCTFail("A route run must target the current manifest pair")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .validationRejected("adapter-route-target-not-current")
            )
        }
        XCTAssertTrue(try fixture.database.fetchAgentRuns().isEmpty)
    }

    func testFakeModelRunStreamsOrderedEventsAndPersistsAcceptedOutput() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let counter = DriverInvocationCounter()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: counter)
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "overview",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        )

        let handle = try await session.start(request)
        let events = try await collect(handle.events)

        XCTAssertEqual(events.map(\.sequence), Array(0..<events.count))
        XCTAssertEqual(events.first?.kind, .queued)
        XCTAssertEqual(events.last?.kind, .completed)
        XCTAssertTrue(events.contains(where: { $0.kind == .toolStarted }))
        XCTAssertTrue(events.contains(where: { $0.kind == .toolFinished }))
        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })
        )
        XCTAssertEqual(run.state, .completed)
        let output = try XCTUnwrap(fixture.database.agentOutput(runID: handle.runID))
        XCTAssertEqual(output.kind, "scoutingSummary")
        XCTAssertEqual(output.disposition, "accepted")
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 1)
        XCTAssertFalse(try fixture.database.fetchTranscriptRecords(runID: handle.runID).isEmpty)
    }

    func testNewGenerationCancelsSlowRunAndDiscardsLateResult() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let slow = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let slowEventStream = slow.events
        let slowCollector = Task {
            var events: [AgentEvent] = []
            for try await event in slowEventStream { events.append(event) }
            return events
        }
        try await Task.sleep(for: .milliseconds(20))
        let fast = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "fast",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))

        let fastEvents = try await collect(fast.events)
        XCTAssertEqual(fastEvents.last?.kind, .completed)
        let slowEvents = try await slowCollector.value
        try await Task.sleep(for: .milliseconds(180))

        let runs = try fixture.database.fetchAgentRuns()
        XCTAssertEqual(runs.first(where: { $0.id == slow.runID })?.state, .cancelled)
        XCTAssertEqual(slowEvents.last?.kind, .cancelled)
        let persistedSlowTerminal = try fixture.database.fetchAgentEvents(
            runID: slow.runID
        ).last
        XCTAssertEqual(slowEvents.last?.id, persistedSlowTerminal?.id)
        XCTAssertEqual(slowEvents.last?.sequence, persistedSlowTerminal?.sequence)
        XCTAssertEqual(slowEvents.last?.kind, persistedSlowTerminal?.kind)
        XCTAssertNil(try fixture.database.agentOutput(runID: slow.runID))
        XCTAssertEqual(runs.first(where: { $0.id == fast.runID })?.state, .completed)
        XCTAssertNotNil(try fixture.database.agentOutput(runID: fast.runID))
    }

    func testCancelSuspensionCannotCancelReplacementRun() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let cancellationBarrier = SessionCancellationBarrier()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter()),
            cancellationInterlock: cancellationBarrier
        )
        let slow = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let slowEventStream = slow.events
        let slowCollector = Task {
            var events: [AgentEvent] = []
            for try await event in slowEventStream { events.append(event) }
            return events
        }
        try await Task.sleep(for: .milliseconds(20))

        let cancellation = Task { await session.cancel() }
        await cancellationBarrier.waitUntilEntered()
        let replacement = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "replacement",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let replacementEvents = try await collect(replacement.events)
        await cancellationBarrier.release()
        await cancellation.value
        let slowEvents = try await slowCollector.value

        let runs = try fixture.database.fetchAgentRuns()
        XCTAssertEqual(
            runs.first(where: { $0.id == slow.runID })?.state,
            .cancelled
        )
        XCTAssertEqual(slowEvents.last?.kind, .cancelled)
        let persistedSlowTerminal = try fixture.database.fetchAgentEvents(
            runID: slow.runID
        ).last
        XCTAssertEqual(slowEvents.last?.id, persistedSlowTerminal?.id)
        XCTAssertEqual(slowEvents.last?.sequence, persistedSlowTerminal?.sequence)
        XCTAssertEqual(slowEvents.last?.kind, persistedSlowTerminal?.kind)
        XCTAssertEqual(replacementEvents.last?.kind, .completed)
        XCTAssertEqual(
            runs.first(where: { $0.id == replacement.runID })?.state,
            .completed
        )
        XCTAssertNotNil(try fixture.database.agentOutput(runID: replacement.runID))
    }

    func testConsumerTerminationCancelsOnlyItsRunAndCannotCancelReplacement() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let abandoned = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let abandonedStream = abandoned.events
        let consumer = Task {
            for try await _ in abandonedStream {}
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()

        let replacement = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "replacement-after-return",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let replacementEvents = try await collect(replacement.events)
        _ = try? await consumer.value
        try await Task.sleep(for: .milliseconds(180))

        let runs = try fixture.database.fetchAgentRuns()
        XCTAssertEqual(
            runs.first(where: { $0.id == abandoned.runID })?.state,
            .cancelled
        )
        XCTAssertEqual(replacementEvents.last?.kind, .completed)
        XCTAssertEqual(
            runs.first(where: { $0.id == replacement.runID })?.state,
            .completed
        )
        XCTAssertNotNil(try fixture.database.agentOutput(runID: replacement.runID))
    }

    func testIDScopedExplicitCancellationCannotCancelReplacementRun() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let old = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let oldStream = old.events
        let oldCollector = Task {
            var events: [AgentEvent] = []
            for try await event in oldStream { events.append(event) }
            return events
        }
        try await Task.sleep(for: .milliseconds(20))

        let replacement = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        // This models AppModel's delayed explicit-cancel task: by the time it
        // reaches the Session actor, a replacement Run is already active.
        await session.cancel(runID: old.runID)
        let replacementEvents = try await collect(replacement.events)
        _ = try? await oldCollector.value

        let runs = try fixture.database.fetchAgentRuns()
        XCTAssertEqual(
            runs.first(where: { $0.id == old.runID })?.state,
            .cancelled
        )
        XCTAssertEqual(replacementEvents.last?.kind, .completed)
        XCTAssertEqual(
            runs.first(where: { $0.id == replacement.runID })?.state,
            .completed
        )
        XCTAssertNotNil(try fixture.database.agentOutput(runID: replacement.runID))
    }

    func testConcurrentStartsInstallOnlyLatestPersistedRun() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let startBarrier = FirstPersistedStartBarrier()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter()),
            startInterlock: startBarrier
        )
        let firstStart = Task {
            try await session.start(AgentRunRequest(
                spaceID: fixture.imported.space.id,
                task: .scoutSpace,
                goal: "first",
                expectedSnapshotIDs: [fixture.imported.snapshot.id]
            ))
        }
        await startBarrier.waitUntilFirstEntered()

        let replacement = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "replacement",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let replacementEvents = try await collect(replacement.events)
        await startBarrier.releaseFirst()
        do {
            _ = try await firstStart.value
            XCTFail("A superseded pending start must not install after its replacement")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .runNotCurrent)
        }

        let runs = try fixture.database.fetchAgentRuns()
        let persistedFirstRunID = await startBarrier.firstRunID()
        let firstRunID = try XCTUnwrap(persistedFirstRunID)
        let firstEvents = try fixture.database.fetchAgentEvents(runID: firstRunID)
        XCTAssertEqual(firstEvents.map(\.sequence), [0, 1])
        XCTAssertEqual(firstEvents.map(\.kind), [.queued, .cancelled])
        let latest = try XCTUnwrap(runs.max(by: { $0.generation < $1.generation }))
        XCTAssertEqual(latest.id, replacement.runID)
        XCTAssertEqual(latest.state, .completed)
        XCTAssertEqual(replacementEvents.last?.kind, .completed)
        XCTAssertTrue(
            runs.filter { $0.id != replacement.runID }
                .allSatisfy { $0.state == .cancelled }
        )
    }

    func testCallerCancellationAfterRunPersistenceTerminalizesWithoutInvokingProvider() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let counter = DriverInvocationCounter()
        let startBarrier = FirstPersistedStartBarrier()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: counter),
            startInterlock: startBarrier
        )
        let startTask = Task {
            try await session.start(AgentRunRequest(
                spaceID: fixture.imported.space.id,
                task: .scoutSpace,
                goal: "cancel-after-persist",
                expectedSnapshotIDs: [fixture.imported.snapshot.id]
            ))
        }
        await startBarrier.waitUntilFirstEntered()

        startTask.cancel()
        await startBarrier.releaseFirst()
        do {
            _ = try await startTask.value
            XCTFail("A cancelled start task must not install a Provider task")
        } catch is CancellationError {
            // Expected: the persisted Run is terminalized before cancellation escapes.
        }

        let persistedRunID = await startBarrier.firstRunID()
        let runID = try XCTUnwrap(persistedRunID)
        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == runID })
        )
        XCTAssertEqual(run.state, .cancelled)
        XCTAssertEqual(run.errorCategory, "cancelled-before-install")
        let events = try fixture.database.fetchAgentEvents(runID: runID)
        XCTAssertEqual(events.map(\.sequence), [0, 1])
        XCTAssertEqual(events.map(\.kind), [.queued, .cancelled])
        XCTAssertNil(try fixture.database.agentOutput(runID: runID))
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 0)
    }

    func testSourceRevisionCoordinatorCancelsInFlightRunBeforeAtomicRefresh() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let runtime = ReadingAgentRuntime(
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let session = try await runtime.session(forSpaceID: fixture.imported.space.id)
        let slow = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            goal: "slow",
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        try await Task.sleep(for: .milliseconds(20))
        let old = fixture.imported.snapshot
        let refreshed = SourceSnapshot(
            id: "\(old.id)-coordinated-refresh",
            sourceID: old.sourceID,
            revision: "coordinated-refresh",
            revisionKind: old.revisionKind,
            digest: String(repeating: "a", count: 64),
            observedAt: .now,
            origin: old.origin,
            managedRelativePath: old.managedRelativePath,
            byteCount: old.byteCount
        )

        try await SourceRevisionCoordinator(
            database: fixture.database,
            agentRuntime: runtime
        ).refresh(to: refreshed)
        _ = try? await collect(slow.events)
        try await Task.sleep(for: .milliseconds(180))

        let cancelled = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == slow.runID })
        )
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.errorCategory, "cancelled")
        XCTAssertNil(try fixture.database.agentOutput(runID: slow.runID))
        XCTAssertEqual(
            try fixture.database.fetchSources().first(where: { $0.id == old.sourceID })?
                .latestSnapshotID,
            refreshed.id
        )

        let next = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [refreshed.id]
        ))
        let nextEvents = try await collect(next.events)
        XCTAssertEqual(nextEvents.last?.kind, .completed)
    }

    func testRemoteProviderWaitsForDisclosureThenExplicitResumeCompletes() async throws {
        let fixture = try await makeSessionFixture(providerKind: .openAIResponses)
        defer { fixture.remove() }
        let counter = DriverInvocationCounter()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: counter)
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        )
        let first = try await session.start(request)
        let firstEvents = try await collect(first.events)

        XCTAssertEqual(firstEvents.last?.kind, .waitingForUser)
        let countBeforeDisclosure = await counter.value
        XCTAssertEqual(countBeforeDisclosure, 0)
        XCTAssertEqual(
            try fixture.database.fetchAgentRuns().first(where: { $0.id == first.runID })?.state,
            .waitingForUser
        )

        try fixture.database.acknowledgeRemoteDisclosure(runID: first.runID)
        let resumed = try await session.resume(runID: first.runID)
        let resumedEvents = try await collect(resumed.events)

        XCTAssertEqual(resumedEvents.last?.kind, .completed)
        let countAfterResume = await counter.value
        XCTAssertEqual(countAfterResume, 1)
        XCTAssertEqual(
            try fixture.database.fetchAgentRuns().first(where: { $0.id == resumed.runID })?.state,
            .completed
        )
    }

    func testDisclosureParentCanCreateOnlyOneResumedRun() async throws {
        let fixture = try await makeSessionFixture(providerKind: .openAIResponses)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let waiting = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(waiting.events)
        try fixture.database.acknowledgeRemoteDisclosure(runID: waiting.runID)

        let child = try await session.resume(runID: waiting.runID)
        do {
            _ = try await session.resume(runID: waiting.runID)
            XCTFail("A disclosure parent must never be resumed twice")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .interrupted)
        }
        _ = try await collect(child.events)

        let runs = try fixture.database.fetchAgentRuns(spaceID: fixture.imported.space.id)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first(where: { $0.id == waiting.runID })?.state, .cancelled)
        XCTAssertEqual(runs.first(where: { $0.id == waiting.runID })?.errorCategory, "resumed")
        XCTAssertEqual(runs.first(where: { $0.id == child.runID })?.state, .completed)
    }

    func testInterruptedRunCanBeAudiblyAbandoned() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let manifest = try fixture.database.currentSnapshotManifest(
            spaceID: fixture.imported.space.id
        )
        let request = AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .answerWithEvidence,
            question: "What is grounded?",
            expectedSnapshotIDs: Set(manifest.values),
            snapshotManifest: manifest
        )
        let profile = try XCTUnwrap(
            fixture.database.providerProfile(forSpaceID: fixture.imported.space.id)
        )
        let run = AgentRun(
            id: UUID().uuidString.lowercased(),
            spaceID: request.spaceID,
            task: request.task,
            generation: 1,
            state: .queued,
            providerProfileID: profile.id,
            providerDestinationIdentity: try ProviderPolicy.destinationIdentity(profile),
            providerRevisionIdentity: try ProviderPolicy.revisionIdentity(profile),
            createdAt: .now,
            startedAt: nil,
            finishedAt: nil,
            errorCategory: nil
        )
        try fixture.database.beginAgentRun(run, request: request)
        XCTAssertNotNil(try fixture.database.transitionAgentRunIfActive(
            runID: run.id,
            generation: run.generation,
            allowedStates: [.queued],
            finalState: .interrupted,
            errorCategory: "app-restart",
            kind: .interrupted,
            phase: "recovery",
            message: "Test interruption"
        ))
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )

        try await session.abandon(runID: run.id)

        let abandoned = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == run.id })
        )
        XCTAssertEqual(abandoned.state, .cancelled)
        XCTAssertEqual(abandoned.errorCategory, "user-abandoned")
        XCTAssertEqual(
            try fixture.database.fetchAgentEvents(runID: run.id).last?.kind,
            .cancelled
        )
        do {
            _ = try await session.resume(runID: run.id)
            XCTFail("An abandoned Run must not be resumable")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .interrupted)
        }
    }

    func testProviderBindingCannotReuseDisclosureAfterConcurrentEndpointChange() async throws {
        let fixture = try await makeSessionFixture(providerKind: .openAIResponses)
        defer { fixture.remove() }
        var endpointA = try XCTUnwrap(
            fixture.database.providerProfile(forSpaceID: fixture.imported.space.id)
        )
        endpointA.endpoint = URL(string: "https://a.example.invalid/v1")
        endpointA.updatedAt = .now
        try fixture.database.saveProviderProfile(endpointA)
        try fixture.database.acknowledgeRemoteDisclosure(
            spaceID: fixture.imported.space.id,
            profileID: endpointA.id
        )
        var endpointB = endpointA
        endpointB.endpoint = URL(string: "https://b.example.invalid/v1")
        endpointB.updatedAt = .now
        try fixture.database.saveProviderProfile(endpointB)

        let barrier = ProviderBindingBarrier()
        let counter = DriverInvocationCounter()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: counter),
            providerBindingInterlock: barrier
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let eventStream = handle.events
        let collector = Task {
            do {
                var events: [AgentEvent] = []
                for try await event in eventStream { events.append(event) }
                return events
            } catch {
                return []
            }
        }
        await barrier.waitUntilEntered()

        endpointA.updatedAt = .now
        try fixture.database.saveProviderProfile(endpointA)
        await barrier.release()
        _ = await collector.value

        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 0)
        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })
        )
        XCTAssertEqual(run.state, .cancelled)
        XCTAssertEqual(run.errorCategory, "provider-configuration-changed")
        XCTAssertEqual(
            run.providerDestinationIdentity,
            try ProviderPolicy.destinationIdentity(endpointB)
        )
        XCTAssertNotEqual(
            run.providerDestinationIdentity,
            try ProviderPolicy.destinationIdentity(endpointA)
        )
    }

    func testSourceRefreshBarrierRejectsRunStartedBetweenCancellationAndCommit() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let runtime = ReadingAgentRuntime(
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let session = try await runtime.session(forSpaceID: fixture.imported.space.id)
        let old = fixture.imported.snapshot
        let refreshed = SourceSnapshot(
            id: "\(old.id)-barrier-refresh",
            sourceID: old.sourceID,
            revision: "barrier-refresh",
            revisionKind: old.revisionKind,
            digest: String(repeating: "b", count: 64),
            observedAt: .now,
            origin: old.origin,
            managedRelativePath: old.managedRelativePath,
            byteCount: old.byteCount
        )
        let barrier = SourceRefreshBarrier()
        let refresh = Task {
            try await SourceRevisionCoordinator(
                database: fixture.database,
                agentRuntime: runtime,
                commitInterlock: barrier
            ).refresh(to: refreshed)
        }
        await barrier.waitUntilEntered()

        do {
            _ = try await session.start(AgentRunRequest(
                spaceID: fixture.imported.space.id,
                task: .scoutSpace,
                expectedSnapshotIDs: [old.id]
            ))
            XCTFail("An existing Session reference must honor the source refresh barrier")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .runNotCurrent)
        }
        do {
            _ = try await runtime.session(forSpaceID: fixture.imported.space.id)
            XCTFail("The Runtime must not vend a Session while the Space is refreshing")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .runNotCurrent)
        }

        await barrier.release()
        try await refresh.value
        let next = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [refreshed.id]
        ))
        let nextEvents = try await collect(next.events)
        XCTAssertEqual(nextEvents.last?.kind, .completed)
    }

    func testOverlappingSourceRefreshLeasesBlockEveryAttachedSpaceUntilLastCommit() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let secondSpaceID = "space:second-\(UUID().uuidString.lowercased())"
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reading_spaces
                        (id, title, is_favorite, created_at, updated_at, last_opened_at)
                    VALUES (?, 'Second Space', 0, ?, ?, NULL)
                    """,
                arguments: [secondSpaceID, Date.now, Date.now]
            )
            try db.execute(
                sql: """
                    INSERT INTO space_sources (space_id, source_id, position, added_at)
                    VALUES (?, ?, 0, ?)
                    """,
                arguments: [secondSpaceID, fixture.imported.source.id, Date.now]
            )
        }
        let runtime = ReadingAgentRuntime(
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let firstSession = try await runtime.session(forSpaceID: fixture.imported.space.id)
        let secondSession = try await runtime.session(forSpaceID: secondSpaceID)
        let old = fixture.imported.snapshot
        let firstSnapshot = SourceSnapshot(
            id: "\(old.id)-overlap-first",
            sourceID: old.sourceID,
            revision: "overlap-first",
            revisionKind: old.revisionKind,
            digest: String(repeating: "c", count: 64),
            observedAt: .now,
            origin: old.origin,
            managedRelativePath: old.managedRelativePath,
            byteCount: old.byteCount
        )
        let secondSnapshot = SourceSnapshot(
            id: "\(old.id)-overlap-second",
            sourceID: old.sourceID,
            revision: "overlap-second",
            revisionKind: old.revisionKind,
            digest: String(repeating: "d", count: 64),
            observedAt: .now,
            origin: old.origin,
            managedRelativePath: old.managedRelativePath,
            byteCount: old.byteCount
        )
        let firstBarrier = SourceRefreshBarrier()
        let secondBarrier = SourceRefreshBarrier()
        let firstRefresh = Task {
            try await SourceRevisionCoordinator(
                database: fixture.database,
                agentRuntime: runtime,
                commitInterlock: firstBarrier
            ).refresh(to: firstSnapshot)
        }
        await firstBarrier.waitUntilEntered()
        let secondRefresh = Task {
            try await SourceRevisionCoordinator(
                database: fixture.database,
                agentRuntime: runtime,
                commitInterlock: secondBarrier
            ).refresh(to: secondSnapshot)
        }
        await secondBarrier.waitUntilEntered()

        for (session, spaceID) in [
            (firstSession, fixture.imported.space.id),
            (secondSession, secondSpaceID),
        ] {
            do {
                _ = try await session.start(AgentRunRequest(
                    spaceID: spaceID,
                    task: .scoutSpace,
                    expectedSnapshotIDs: [old.id]
                ))
                XCTFail("Every attached Space must be blocked by the shared refresh lease")
            } catch {
                XCTAssertEqual(error as? ReadingAgentError, .runNotCurrent)
            }
        }

        await firstBarrier.release()
        try await firstRefresh.value
        do {
            _ = try await secondSession.start(AgentRunRequest(
                spaceID: secondSpaceID,
                task: .scoutSpace,
                expectedSnapshotIDs: [firstSnapshot.id]
            ))
            XCTFail("Completing one overlapping refresh must not release the other lease")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .runNotCurrent)
        }

        await secondBarrier.release()
        try await secondRefresh.value
        let next = try await secondSession.start(AgentRunRequest(
            spaceID: secondSpaceID,
            task: .scoutSpace,
            expectedSnapshotIDs: [secondSnapshot.id]
        ))
        let events = try await collect(next.events)
        XCTAssertEqual(events.last?.kind, .completed)
        XCTAssertEqual(
            try fixture.database.fetchSources().first(where: {
                $0.id == fixture.imported.source.id
            })?.latestSnapshotID,
            secondSnapshot.id
        )
    }

    func testRepeatedInvalidModelOutputTerminatesAtModelBudget() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: RejectingDriverFactory(),
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))

        do {
            _ = try await collect(handle.events)
            XCTFail("Expected the correction loop to stop at its model budget")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .modelRoundBudgetExceeded(2))
        }

        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })
        )
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.errorCategory, "model-budget")
        let events = try fixture.database.fetchAgentEvents(runID: handle.runID)
        XCTAssertEqual(events.filter { $0.kind == .validation }.count, 2)
        XCTAssertEqual(events.last?.kind, .failed)
    }

    func testCustomRuntimeLimitsReachDriverContext() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let captured = DriverContextCapture()
        let limits = AgentRuntimeLimits(
            maxModelRounds: 3,
            promptUtilization: 0.42,
            fallbackContextTokens: 10_000
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: CapturingDriverFactory(capture: captured),
            limits: limits
        )

        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(handle.events)

        let capturedLimits = await captured.limits
        let received = try XCTUnwrap(capturedLimits)
        XCTAssertEqual(received, limits)
        XCTAssertEqual(received.promptTokenBudget(contextWindow: nil), 4_200)
    }

    func testRealDriverPersistsBoundedContextAndModelTelemetryAcrossRuns() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let model = RuntimeStructuredLanguageModel(summary: "bounded")
        let limits = AgentRuntimeLimits(
            maxModelRounds: 4,
            maxResponseTokens: 1_024,
            maxResponseBytes: 4_096
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: DefaultReadingAgentDriverFactory(
                languageModelFactory: RuntimeLanguageModelFactory(model: model)
            ),
            limits: limits
        )

        let first = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let firstEvents = try await collect(first.events)
        XCTAssertEqual(firstEvents.last?.kind, .completed)
        XCTAssertNotEqual(firstEvents.last?.metadata["inputTokens"], "<redacted>")
        XCTAssertNotNil(firstEvents.last?.metadata["durationMilliseconds"])
        XCTAssertEqual(
            firstEvents.last?.metadata["usageMeasurement"],
            "host-conservative-upper-bound"
        )
        let firstSnapshots = try fixture.database.fetchAgentContextSnapshots(runID: first.runID)
        XCTAssertGreaterThanOrEqual(firstSnapshots.count, 2)
        let firstMetrics = try fixture.database.fetchAgentModelCallMetrics(runID: first.runID)
        XCTAssertEqual(firstMetrics.count, 1)
        XCTAssertGreaterThan(firstMetrics[0].inputBytes, 0)
        XCTAssertGreaterThan(firstMetrics[0].outputBytes, 0)
        XCTAssertGreaterThanOrEqual(firstMetrics[0].durationMilliseconds, 0)

        let second = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(second.events)

        let inputEntryCounts = await model.inputEntryCounts()
        XCTAssertEqual(inputEntryCounts.count, 2)
        XCTAssertGreaterThan(inputEntryCounts[1], inputEntryCounts[0])
        XCTAssertEqual(
            try fixture.database.fetchAgentContextSnapshots(runID: first.runID),
            firstSnapshots
        )
        let responseTokenLimits = await model.responseTokenLimits()
        XCTAssertTrue(responseTokenLimits.allSatisfy {
            ($0 ?? .max) <= limits.responseTokenBudget(contextWindow: nil)
        })
    }

    func testRealDriverRejectsUncooperativeOversizedResponseAndAuditsIt() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let model = RuntimeStructuredLanguageModel(
            summary: String(repeating: "oversized", count: 1_024)
        )
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            maxResponseTokens: 32,
            maxResponseBytes: 128
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: DefaultReadingAgentDriverFactory(
                languageModelFactory: RuntimeLanguageModelFactory(model: model)
            ),
            limits: limits
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))

        do {
            _ = try await collect(handle.events)
            XCTFail("The host must reject output above its byte ceiling")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .responseBudgetExceeded(128))
        }
        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })
        )
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.errorCategory, "response-budget")
        let metrics = try fixture.database.fetchAgentModelCallMetrics(runID: handle.runID)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].outcome, .failed)
        XCTAssertGreaterThan(metrics[0].outputBytes, 128)
        XCTAssertEqual(
            try fixture.database.fetchTranscriptRecords(runID: handle.runID).last?
                .disposition,
            .partialFailure
        )
        let responseTokenLimits = await model.responseTokenLimits()
        XCTAssertEqual(responseTokenLimits, [32])
    }

    func testOversizedFailureAuditStoresDigestMarkerInsteadOfFullEntry() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let model = RuntimeStructuredLanguageModel(
            summary: String(repeating: "sensitive-large-output", count: 8_192)
        )
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            artifactSpillBytes: 512,
            maxResponseTokens: 32,
            maxResponseBytes: 128
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: DefaultReadingAgentDriverFactory(
                languageModelFactory: RuntimeLanguageModelFactory(model: model)
            ),
            limits: limits
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))

        do {
            _ = try await collect(handle.events)
            XCTFail("The oversized model entry must fail")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .responseBudgetExceeded(128))
        }

        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: handle.runID)
                .last(where: { $0.disposition == .partialFailure })
        )
        XCTAssertLessThanOrEqual(partial.content.count, 512)
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(with: partial.content) as? [String: Any]
        )
        XCTAssertEqual(marker["kind"] as? String, "truncated-model-failure-audit")
        XCTAssertEqual((marker["sha256"] as? String)?.count, 64)
        XCTAssertGreaterThan(marker["originalByteCount"] as? Int ?? 0, 512)
        XCTAssertFalse(String(decoding: partial.content, as: UTF8.self).contains(
            "sensitive-large-output"
        ))
    }

    func testControlledStreamPersistsFullAggregationAndCumulativeTelemetry() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = ManySmallDeltaLanguageModel(count: 20, chunk: "abcdefgh")
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            maxResponseTokens: 4_096,
            maxResponseBytes: 4_096,
            maxTransportResponseBytes: 16_384
        )
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: limits
        )

        var yielded = 0
        for try await _ in harness.model.stream(
            transcript: harness.transcript,
            options: nil
        ) {
            yielded += 1
        }

        XCTAssertEqual(yielded, 20)
        let records = try fixture.database.fetchTranscriptRecords(runID: harness.run.id)
        let assistant = try XCTUnwrap(records.last(where: { $0.role == .assistant }))
        XCTAssertEqual(assistant.disposition, .complete)
        let persistedEntry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: assistant.content).first
        )
        XCTAssertEqual(
            responseText(in: persistedEntry),
            String(repeating: "abcdefgh", count: 20)
        )
        let snapshots = try fixture.database.fetchAgentContextSnapshots(runID: harness.run.id)
        let finalSnapshot = try XCTUnwrap(snapshots.last)
        let fullTranscript = try JSONDecoder().decode(
            Transcript.self,
            from: finalSnapshot.fullTranscriptJSON
        )
        XCTAssertEqual(
            responseText(in: try XCTUnwrap(fullTranscript.last)),
            String(repeating: "abcdefgh", count: 20)
        )
        let metrics = try fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].outcome, .succeeded)
        XCTAssertGreaterThan(metrics[0].outputBytes, assistant.content.count)
        let responseTokenLimits = await base.responseTokenLimits()
        XCTAssertEqual(responseTokenLimits, [4_096])
    }

    func testControlledAnthropicStreamNormalizesCumulativePrefixes() async throws {
        let fixture = try await makeSessionFixture(providerKind: .anthropicMessages)
        defer { fixture.remove() }
        let base = CumulativePrefixLanguageModel(prefixes: ["H", "He", "Hel", "Hello"])
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(
                maxModelRounds: 2,
                maxResponseTokens: 4_096,
                maxResponseBytes: 4_096,
                maxTransportResponseBytes: 16_384
            )
        )

        var yielded = ""
        for try await entry in harness.model.stream(
            transcript: harness.transcript,
            options: nil
        ) {
            yielded += responseText(in: entry)
        }

        XCTAssertEqual(yielded, "Hello")
        let assistant = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .complete && $0.role == .assistant })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: assistant.content).first
        )
        XCTAssertEqual(responseText(in: entry), "Hello")
        let metric = try XCTUnwrap(
            fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id).first
        )
        XCTAssertEqual(metric.outcome, .succeeded)
        XCTAssertGreaterThan(metric.outputBytes, assistant.content.count)
    }

    func testControlledAnthropicStreamUsesExactUTF8PrefixesForCombiningMarksAndZWJ() async throws {
        let fixture = try await makeSessionFixture(providerKind: .anthropicMessages)
        defer { fixture.remove() }
        let expected = "e\u{301}👩\u{200D}💻"
        let base = CumulativePrefixLanguageModel(prefixes: [
            "e",
            "e\u{301}",
            "e\u{301}👩",
            "e\u{301}👩\u{200D}",
            expected,
        ])
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(
                maxModelRounds: 2,
                maxResponseTokens: 4_096,
                maxResponseBytes: 4_096,
                maxTransportResponseBytes: 16_384
            )
        )

        var yielded = ""
        for try await entry in harness.model.stream(
            transcript: harness.transcript,
            options: nil
        ) {
            yielded += responseText(in: entry)
        }

        XCTAssertEqual(Array(yielded.utf8), Array(expected.utf8))
        let assistant = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .complete && $0.role == .assistant })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: assistant.content).first
        )
        XCTAssertEqual(
            Array(responseText(in: entry).utf8),
            Array(expected.utf8)
        )
    }

    func testControlledAnthropicStreamRejectsCanonicalEquivalentNonBytePrefix() async throws {
        let fixture = try await makeSessionFixture(providerKind: .anthropicMessages)
        defer { fixture.remove() }
        let base = CumulativePrefixLanguageModel(prefixes: ["é", "e\u{301}x"])
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )

        do {
            for try await _ in harness.model.stream(
                transcript: harness.transcript,
                options: nil
            ) { }
            XCTFail("Canonical equivalence must not substitute for an exact byte prefix")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .providerUnavailable("anthropic-stream-prefix")
            )
        }

        let metric = try XCTUnwrap(
            fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id).first
        )
        XCTAssertEqual(metric.outcome, .failed)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(Array(responseText(in: entry).utf8), Array("é".utf8))
    }

    func testControlledStreamRejectsManySmallDeltasAtCumulativeLimit() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = ManySmallDeltaLanguageModel(count: 200, chunk: "abcdefgh")
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            maxResponseTokens: 4_096,
            maxResponseBytes: 512,
            maxTransportResponseBytes: 8_192
        )
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: limits
        )

        do {
            for try await _ in harness.model.stream(
                transcript: harness.transcript,
                options: nil
            ) { }
            XCTFail("Many small deltas must not bypass the cumulative response limit")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .responseBudgetExceeded(512))
        }
        let metrics = try fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].outcome, .failed)
        XCTAssertGreaterThan(metrics[0].outputBytes, 512)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        XCTAssertEqual(partial.role, .assistant)
        let partialEntry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertFalse(responseText(in: partialEntry).isEmpty)
        let mutableSnapshot = try XCTUnwrap(
            fixture.database.fetchAgentSession(spaceID: harness.run.spaceID)?
                .transcriptJSON
        )
        XCTAssertTrue(
            try JSONDecoder().decode(Transcript.self, from: mutableSnapshot)
                .allSatisfy { responseText(in: $0).isEmpty }
        )
    }

    func testControlledStreamAuditsPartialOutputBeforeNetworkFailure() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = FailingDeltaLanguageModel(
            chunks: ["first-", "second-", "third"],
            failure: .providerUnavailable("simulated-network-failure")
        )
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(
                maxModelRounds: 2,
                maxResponseTokens: 4_096,
                maxResponseBytes: 4_096,
                maxTransportResponseBytes: 16_384
            )
        )

        do {
            for try await _ in harness.model.stream(
                transcript: harness.transcript,
                options: nil
            ) { }
            XCTFail("A stream failure after deltas must propagate")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .providerUnavailable("simulated-network-failure")
            )
        }

        let metric = try XCTUnwrap(
            fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id).first
        )
        XCTAssertEqual(metric.outcome, .failed)
        XCTAssertGreaterThan(metric.outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(responseText(in: entry), "first-second-third")
        let mutableSnapshot = try XCTUnwrap(
            fixture.database.fetchAgentSession(spaceID: harness.run.spaceID)?
                .transcriptJSON
        )
        XCTAssertTrue(
            try JSONDecoder().decode(Transcript.self, from: mutableSnapshot)
                .allSatisfy { responseText(in: $0).isEmpty }
        )
    }

    func testControlledStreamCancellationAuditsFirstDeltaAfterRunIsCancelled() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let barrier = ModelCallBarrier()
        let base = CancellableDeltaLanguageModel(barrier: barrier)
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )
        let consumer = Task {
            for try await _ in harness.model.stream(
                transcript: harness.transcript,
                options: nil
            ) { }
        }
        await barrier.waitUntilEntered()
        _ = try fixture.database.transitionAgentRunIfActive(
            runID: harness.run.id,
            generation: harness.run.generation,
            allowedStates: [.running],
            finalState: .cancelled,
            errorCategory: "cancelled",
            kind: .cancelled,
            phase: "test",
            message: "cancelled"
        )
        await harness.model.recorder.finish()
        await barrier.cancel()
        do {
            try await consumer.value
            XCTFail("The stream consumer must observe cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let metrics = try await waitForModelMetrics(
            database: fixture.database,
            runID: harness.run.id
        )
        XCTAssertEqual(metrics.count, 1)
        let metric = try XCTUnwrap(metrics.first)
        XCTAssertEqual(metric.outcome, .cancelled)
        XCTAssertGreaterThan(metric.outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(responseText(in: entry), "first")
    }

    func testSessionNonStreamingCancellationAuditsTerminalCancelledRun() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let barrier = ModelCallBarrier()
        let base = CancellableGenerateLanguageModel(barrier: barrier)
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: DefaultReadingAgentDriverFactory(
                languageModelFactory: RuntimeLanguageModelFactory(model: base)
            ),
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let collector = Task {
            var events: [AgentEvent] = []
            do {
                for try await event in handle.events { events.append(event) }
                return (events, nil as String?)
            } catch {
                return (events, AgentRedactor.category(for: error))
            }
        }
        await barrier.waitUntilEntered()
        await session.cancel()
        let collection = await collector.value
        XCTAssertNil(collection.1)
        XCTAssertEqual(collection.0.last?.kind, .cancelled)

        let metrics = try await waitForModelMetrics(
            database: fixture.database,
            runID: handle.runID
        )
        XCTAssertEqual(metrics.count, 1)
        let metric = try XCTUnwrap(metrics.first)
        XCTAssertEqual(metric.outcome, .cancelled)
        XCTAssertEqual(metric.outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: handle.runID)
                .last(where: { $0.disposition == .partialFailure })
        )
        XCTAssertEqual(partial.content, Data("null".utf8))
        XCTAssertEqual(
            try fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })?.state,
            .cancelled
        )
    }

    func testDurableCancellationWinsOverLateNonCooperativeSecretFailure() async throws {
        let fixture = try await makeSessionFixture(providerKind: .openAIResponses)
        defer { fixture.remove() }
        let profile = try XCTUnwrap(
            fixture.database.providerProfile(forSpaceID: fixture.imported.space.id)
        )
        try fixture.database.acknowledgeRemoteDisclosure(
            spaceID: fixture.imported.space.id,
            profileID: profile.id
        )
        let secretStore = NonCooperativeMissingSecretStore()
        let cancellationBarrier = SessionCancellationBarrier()
        let counter = DriverInvocationCounter()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: secretStore,
            driverFactory: FakeDriverFactory(counter: counter),
            cancellationInterlock: cancellationBarrier
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let eventStream = handle.events
        let collector = Task {
            var events: [AgentEvent] = []
            do {
                for try await event in eventStream { events.append(event) }
                return (events, nil as String?)
            } catch {
                return (events, AgentRedactor.category(for: error))
            }
        }
        await secretStore.waitUntilSecretRead()

        let cancellation = Task { await session.cancel() }
        await cancellationBarrier.waitUntilEntered()
        await secretStore.releaseMissingSecret()
        let collection = await collector.value
        await cancellationBarrier.release()
        await cancellation.value

        XCTAssertNil(collection.1)
        XCTAssertEqual(collection.0.last?.kind, .cancelled)
        let persistedEvents = try fixture.database.fetchAgentEvents(runID: handle.runID)
        XCTAssertEqual(collection.0.last?.id, persistedEvents.last?.id)
        XCTAssertEqual(collection.0.last?.sequence, persistedEvents.last?.sequence)
        XCTAssertEqual(
            try fixture.database.agentRunState(runID: handle.runID),
            .cancelled
        )
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 0)
    }

    func testNonCooperativeGenerateReturningAfterReplacementAuditsCancellation() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let barrier = NonCooperativeReturnBarrier()
        let base = NonCooperativeReturningLanguageModel(barrier: barrier)
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )
        let call = Task {
            try await harness.model.generate(
                transcript: harness.transcript,
                options: nil
            )
        }
        await barrier.waitUntilEntered()
        let replacement = try await cancelHarnessAndBeginReplacement(
            fixture: fixture,
            harness: harness
        )
        call.cancel()
        await barrier.release()

        do {
            _ = try await call.value
            XCTFail("A late normal return must resolve to cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            try fixture.database.fetchAgentSession(spaceID: harness.run.spaceID)?.generation,
            replacement.generation
        )
        let metrics = try await waitForModelMetrics(
            database: fixture.database,
            runID: harness.run.id
        )
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].outcome, .cancelled)
        XCTAssertGreaterThan(metrics[0].outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(responseText(in: entry), "late-normal-return")
        XCTAssertFalse(
            try fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .contains(where: { $0.disposition == .complete && $0.role == .assistant })
        )
    }

    func testNonCooperativeStreamEndingAfterReplacementAuditsCancellation() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let barrier = NonCooperativeReturnBarrier()
        let base = NonCooperativeFinishingStreamLanguageModel(barrier: barrier)
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: AgentRuntimeLimits(maxModelRounds: 2)
        )
        let consumer = Task {
            for try await _ in harness.model.stream(
                transcript: harness.transcript,
                options: nil
            ) { }
        }
        await barrier.waitUntilEntered()
        let replacement = try await cancelHarnessAndBeginReplacement(
            fixture: fixture,
            harness: harness
        )
        await barrier.release()

        do {
            try await consumer.value
            XCTFail("A late normal stream end must resolve to cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            try fixture.database.fetchAgentSession(spaceID: harness.run.spaceID)?.generation,
            replacement.generation
        )
        let metrics = try await waitForModelMetrics(
            database: fixture.database,
            runID: harness.run.id
        )
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].outcome, .cancelled)
        XCTAssertGreaterThan(metrics[0].outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(responseText(in: entry), "first")
        XCTAssertFalse(
            try fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .contains(where: { $0.disposition == .complete && $0.role == .assistant })
        )
    }

    func testNonCooperativeSummaryReturningAfterReplacementAuditsCancellation() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let barrier = NonCooperativeReturnBarrier()
        let base = NonCooperativeReturningLanguageModel(barrier: barrier)
        let limits = AgentRuntimeLimits(maxModelRounds: 2)
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: base,
            limits: limits
        )
        let summarizer = BaseModelTranscriptSummarizer(
            model: base,
            profile: harness.model.profile,
            database: fixture.database,
            spaceID: harness.run.spaceID,
            runID: harness.run.id,
            budget: harness.model.budget,
            clock: harness.model.clock,
            generation: harness.run.generation,
            limits: limits,
            telemetry: harness.model.telemetry,
            inputTokenBudget: limits.promptTokenBudget(contextWindow: nil)
        )
        let call = Task {
            try await summarizer.summarize(
                [AgentContextItem(
                    id: "old",
                    kind: .assistant,
                    content: "old factual state",
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "old",
                    phaseCompleted: true
                )],
                maximumTokens: 1_024
            )
        }
        await barrier.waitUntilEntered()
        let replacement = try await cancelHarnessAndBeginReplacement(
            fixture: fixture,
            harness: harness
        )
        call.cancel()
        await barrier.release()

        do {
            _ = try await call.value
            XCTFail("A late summary return must resolve to cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            try fixture.database.fetchAgentSession(spaceID: harness.run.spaceID)?.generation,
            replacement.generation
        )
        let metrics = try await waitForModelMetrics(
            database: fixture.database,
            runID: harness.run.id
        )
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].kind, .summary)
        XCTAssertEqual(metrics[0].outcome, .cancelled)
        XCTAssertGreaterThan(metrics[0].outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        XCTAssertEqual(responseText(in: entry), "late-normal-return")
    }

    func testSummaryToolCallIsFailedAndStoredOnlyAsPartialAudit() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let model = SummaryToolCallLanguageModel()
        let limits = AgentRuntimeLimits(maxModelRounds: 2)
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: model,
            limits: limits
        )
        let summarizer = BaseModelTranscriptSummarizer(
            model: model,
            profile: harness.model.profile,
            database: fixture.database,
            spaceID: harness.run.spaceID,
            runID: harness.run.id,
            budget: harness.model.budget,
            clock: harness.model.clock,
            generation: harness.run.generation,
            limits: limits,
            telemetry: harness.model.telemetry,
            inputTokenBudget: limits.promptTokenBudget(contextWindow: nil)
        )

        do {
            _ = try await summarizer.summarize([
                AgentContextItem(
                    id: "old",
                    kind: .assistant,
                    content: "prior state",
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "old",
                    phaseCompleted: true
                ),
            ], maximumTokens: 64)
            XCTFail("A summary tool call is not a valid summary response")
        } catch {
            XCTAssertEqual(
                error as? ReadingAgentError,
                .invalidStructuredOutput("summary-response")
            )
        }

        let metric = try XCTUnwrap(
            fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id).first
        )
        XCTAssertEqual(metric.kind, .summary)
        XCTAssertEqual(metric.outcome, .failed)
        XCTAssertGreaterThan(metric.outputBytes, 0)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        let entry = try XCTUnwrap(
            try JSONDecoder().decode(Transcript.self, from: partial.content).first
        )
        if case .toolCalls = entry {
            // Expected: audit-only; the mutable session never receives this entry.
        } else {
            XCTFail("Expected the rejected summary tool call in the audit record")
        }
        if let mutableSnapshot = try fixture.database.fetchAgentSession(
            spaceID: harness.run.spaceID
        )?.transcriptJSON {
            XCTAssertFalse(
                try JSONDecoder().decode(Transcript.self, from: mutableSnapshot)
                    .contains { entry in
                        if case .toolCalls = entry { return true }
                        return false
                    }
            )
        }
    }

    func testSummaryTransportOverflowRecordsObservedBytesAndPartialAudit() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let server = try LoopbackOversizedResponseServer()
        defer { server.stop() }
        let lease = try ProviderEndpointTransport.makeLease(
            endpoint: server.baseURL,
            maximumResponseBytes: 256,
            maximumCumulativeResponseBytes: 256
        )
        let session = try lease.construct { URLSession(configuration: .default) }
        defer { session.invalidateAndCancel() }
        let model = TransportOverflowSummaryLanguageModel(
            session: session,
            url: server.baseURL.appendingPathComponent("oversized-http")
        )
        let limits = AgentRuntimeLimits(
            maxModelRounds: 2,
            maxResponseTokens: 64,
            maxResponseBytes: 256,
            maxTransportResponseBytes: 256
        )
        let harness = try await makeControlledModelHarness(
            fixture: fixture,
            base: model,
            limits: limits
        )
        let summarizer = BaseModelTranscriptSummarizer(
            model: model,
            profile: harness.model.profile,
            database: fixture.database,
            spaceID: harness.run.spaceID,
            runID: harness.run.id,
            budget: harness.model.budget,
            clock: harness.model.clock,
            generation: harness.run.generation,
            limits: limits,
            telemetry: harness.model.telemetry,
            transportLease: lease,
            inputTokenBudget: limits.promptTokenBudget(contextWindow: nil)
        )

        do {
            _ = try await summarizer.summarize([
                AgentContextItem(
                    id: "old",
                    kind: .assistant,
                    content: "prior state",
                    observationDigest: nil,
                    artifactID: nil,
                    phase: "old",
                    phaseCompleted: true
                ),
            ], maximumTokens: 64)
            XCTFail("Transport overflow must fail the summary call")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .responseBudgetExceeded(256))
        }

        let metric = try XCTUnwrap(
            fixture.database.fetchAgentModelCallMetrics(runID: harness.run.id).first
        )
        XCTAssertEqual(metric.kind, .summary)
        XCTAssertEqual(metric.outcome, .failed)
        XCTAssertGreaterThan(metric.outputBytes, 256)
        let partial = try XCTUnwrap(
            fixture.database.fetchTranscriptRecords(runID: harness.run.id)
                .last(where: { $0.disposition == .partialFailure })
        )
        XCTAssertEqual(partial.content, Data("null".utf8))
    }

    func testLowConfidenceAdapterCandidateRequiresExplicitConfirmation() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let candidate = makeConfirmationCandidate(
            base: base,
            id: "low-confidence-candidate",
            reason: "Bounded candidate requiring user confirmation"
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: AdapterCandidateDriverFactory(candidate: candidate)
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let events = try await collect(handle.events)
        XCTAssertEqual(events.last?.kind, .waitingForUser)

        do {
            _ = try await session.resume(runID: handle.runID)
            XCTFail("A low-confidence choice must not be treated as a resumable network run")
        } catch {
            XCTAssertEqual(error as? ReadingAgentError, .interrupted)
        }

        let confirmed = try await session.confirmAdapterCandidate(runID: handle.runID)
        XCTAssertTrue(confirmed.isUserOverride)
        XCTAssertNotEqual(confirmed.id, candidate.id)
        XCTAssertTrue(confirmed.id.hasPrefix("agent-adapter-plan:"))
        let stored = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        XCTAssertTrue(stored.isUserOverride)
        let output = try XCTUnwrap(fixture.database.agentOutput(runID: handle.runID))
        XCTAssertEqual(output.disposition, "userConfirmed")
        let run = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == handle.runID })
        )
        XCTAssertEqual(run.state, .completed)
        XCTAssertNil(run.errorCategory)
        XCTAssertEqual(
            try fixture.database.fetchAgentEvents(runID: handle.runID).last?.kind,
            .completed
        )
    }

    func testStartingNewRunSupersedesWaitingAdapterCandidate() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let candidate = makeConfirmationCandidate(
            base: base,
            id: "candidate-to-supersede",
            reason: "This candidate must not become a persistent ghost"
        )
        let candidateSession = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: AdapterCandidateDriverFactory(candidate: candidate)
        )
        let waiting = try await candidateSession.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(waiting.events)

        let nextSession = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: DriverInvocationCounter())
        )
        let next = try await nextSession.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .scoutSpace,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(next.events)

        let oldRun = try XCTUnwrap(
            fixture.database.fetchAgentRuns().first(where: { $0.id == waiting.runID })
        )
        XCTAssertEqual(oldRun.state, .cancelled)
        XCTAssertEqual(oldRun.errorCategory, "superseded")
        XCTAssertEqual(
            try fixture.database.agentOutput(runID: waiting.runID)?.disposition,
            "superseded"
        )
    }

    func testDismissingAdapterCandidatePreservesAuditableDisposition() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let candidate = makeConfirmationCandidate(
            base: base,
            id: "dismissed-candidate",
            reason: "Candidate the user does not adopt"
        )
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: AdapterCandidateDriverFactory(candidate: candidate)
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(handle.events)

        try await session.dismissAdapterCandidate(runID: handle.runID)

        XCTAssertEqual(
            try fixture.database.agentOutput(runID: handle.runID)?.disposition,
            "userDismissed"
        )
        XCTAssertEqual(
            try fixture.database.fetchAgentRuns()
                .first(where: { $0.id == handle.runID })?.errorCategory,
            "user-dismissed"
        )
    }

    func testCancellationAtFinalCommitCannotInstallStaleAdapterPlan() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let candidate = AdapterPlan(
            id: "stale-at-commit",
            schemaVersion: base.schemaVersion,
            sourceID: base.sourceID,
            snapshotID: base.snapshotID,
            primaryAdapterID: base.primaryAdapterID,
            auxiliaryAdapterIDs: base.auxiliaryAdapterIDs,
            capabilityRoutes: base.capabilityRoutes,
            evidence: base.evidence,
            confidence: min(base.confidence, 0.95),
            reason: "Must be discarded when cancellation wins the commit race",
            isUserOverride: false,
            createdAt: .distantFuture
        )
        let barrier = FinalCommitBarrier()
        let session = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: AdapterCandidateDriverFactory(candidate: candidate),
            commitInterlock: barrier
        )
        let handle = try await session.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        let eventStream = handle.events
        let collector = Task {
            var events: [AgentEvent] = []
            for try await event in eventStream { events.append(event) }
            return events
        }
        await barrier.waitUntilEntered()

        await session.cancel()
        await barrier.release()
        _ = try? await collector.value
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(try fixture.database.agentOutput(runID: handle.runID))
        XCTAssertEqual(
            try fixture.database.fetchAgentRuns()
                .first(where: { $0.id == handle.runID })?.state,
            .cancelled
        )
        XCTAssertEqual(
            try fixture.database.fetchAdapterPlan(snapshotID: base.snapshotID)?.id,
            base.id
        )
    }

    func testRestartedLowConfidenceCandidateCanBeConfirmedWithoutNetworkReplay() async throws {
        let fixture = try await makeSessionFixture(providerKind: .ollama)
        defer { fixture.remove() }
        let base = try XCTUnwrap(
            fixture.database.fetchAdapterPlan(snapshotID: fixture.imported.snapshot.id)
        )
        let candidate = makeConfirmationCandidate(
            base: base,
            id: "restart-candidate",
            reason: "Local confirmation survives restart"
        )
        let original = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: fixture.database,
            toolHost: fixture.toolHost,
            validator: fixture.validator,
            secretStore: fixture.secrets,
            driverFactory: AdapterCandidateDriverFactory(candidate: candidate)
        )
        let handle = try await original.start(AgentRunRequest(
            spaceID: fixture.imported.space.id,
            task: .routeAdapters,
            targetSourceID: fixture.imported.source.id,
            targetSnapshotID: fixture.imported.snapshot.id,
            expectedSnapshotIDs: [fixture.imported.snapshot.id]
        ))
        _ = try await collect(handle.events)

        let reopened = try LibraryDatabase(rootURL: fixture.root)
        let registry = try AdapterRegistry.standard()
        let coordinator = AdapterCoordinator(database: reopened, registry: registry)
        let counter = DriverInvocationCounter()
        let restarted = try ReadingAgentSession(
            spaceID: fixture.imported.space.id,
            database: reopened,
            toolHost: ReadingToolHost(
                database: reopened,
                coordinator: coordinator,
                registry: registry
            ),
            validator: AgentOutputValidator(database: reopened, registry: registry),
            secretStore: fixture.secrets,
            driverFactory: FakeDriverFactory(counter: counter)
        )

        let confirmed = try await restarted.confirmAdapterCandidate(runID: handle.runID)

        XCTAssertTrue(confirmed.isUserOverride)
        let replayCount = await counter.value
        XCTAssertEqual(replayCount, 0)
        XCTAssertEqual(
            try reopened.fetchAgentRuns().first(where: { $0.id == handle.runID })?.state,
            .completed
        )
        let eventKinds = try reopened.fetchAgentEvents(runID: handle.runID).map(\.kind)
        XCTAssertTrue(eventKinds.contains(.interrupted))
        XCTAssertEqual(eventKinds.last, .completed)
    }

    private func collect(
        _ stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func waitForModelMetrics(
        database: LibraryDatabase,
        runID: String
    ) async throws -> [AgentModelCallMetric] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            let metrics = try database.fetchAgentModelCallMetrics(runID: runID)
            if !metrics.isEmpty { return metrics }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try database.fetchAgentModelCallMetrics(runID: runID)
    }
}

private actor DriverInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct RuntimeLanguageModelFactory: ProviderLanguageModelFactory {
    let model: any LanguageModel

    func makeModel(
        profile: ProviderProfile,
        secret: String?,
        maximumResponseBytes: Int,
        maximumCumulativeResponseBytes: Int?
    ) -> ProviderLanguageModelInstance {
        ProviderLanguageModelInstance(model: model, transportLease: nil)
    }
}

private final class RuntimeStructuredLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let summary: String
    private let state = RuntimeLanguageModelState()

    init(summary: String) {
        self.summary = summary
    }

    func supports(locale: Locale) -> Bool { true }

    func inputEntryCounts() async -> [Int] { await state.inputEntryCounts }
    func responseTokenLimits() async -> [Int?] { await state.responseTokenLimits }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        await state.record(
            inputEntryCount: transcript.count,
            responseTokenLimit: options?.maximumResponseTokens
        )
        let payload = try JSONEncoder().encode(["summary": summary])
        let payloadJSON = String(decoding: payload, as: UTF8.self)
        let envelope = try JSONEncoder().encode([
            "kind": "scoutingSummary",
            "payloadJSON": payloadJSON,
        ])
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.structure(Transcript.StructuredSegment(
                source: "test-model",
                content: try GeneratedContent(json: String(decoding: envelope, as: UTF8.self))
            ))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ManySmallDeltaLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let count: Int
    private let chunk: String
    private let state = StreamResponseOptionRecorder()

    init(count: Int, chunk: String) {
        self.count = count
        self.chunk = chunk
    }

    func supports(locale: Locale) -> Bool { true }

    func responseTokenLimits() async -> [Int?] { await state.values }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: chunk))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.state.append(options?.maximumResponseTokens)
                for _ in 0..<self.count {
                    try Task.checkCancellation()
                    continuation.yield(.response(Transcript.Response(
                        assetIDs: [],
                        segments: [.text(.init(content: self.chunk))]
                    )))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class CumulativePrefixLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let prefixes: [String]

    init(prefixes: [String]) {
        self.prefixes = prefixes
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: prefixes.last ?? ""))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            for prefix in prefixes {
                continuation.yield(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: prefix))]
                )))
            }
            continuation.finish()
        }
    }
}

private actor ModelCallBarrier {
    private var entered = false
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForCancellation() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func cancel() {
        cancelled = true
        let current = cancellationWaiters
        cancellationWaiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class CancellableDeltaLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let barrier: ModelCallBarrier

    init(barrier: ModelCallBarrier) {
        self.barrier = barrier
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        throw CancellationError()
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: "first"))]
                )))
                await self.barrier.enter()
                await self.barrier.waitForCancellation()
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class CancellableGenerateLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let barrier: ModelCallBarrier

    init(barrier: ModelCallBarrier) {
        self.barrier = barrier
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        await barrier.enter()
        try await Task.sleep(for: .seconds(60))
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: "unreachable"))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor NonCooperativeReturnBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let currentEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        currentEntryWaiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        currentReleaseWaiters.forEach { $0.resume() }
    }
}

private final class NonCooperativeReturningLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let barrier: NonCooperativeReturnBarrier

    init(barrier: NonCooperativeReturnBarrier) {
        self.barrier = barrier
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        await barrier.enterAndWait()
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: "late-normal-return"))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class NonCooperativeFinishingStreamLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let barrier: NonCooperativeReturnBarrier

    init(barrier: NonCooperativeReturnBarrier) {
        self.barrier = barrier
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: "unused"))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(Transcript.Response(
                assetIDs: [],
                segments: [.text(.init(content: "first"))]
            )))
            Task {
                await self.barrier.enterAndWait()
                continuation.finish()
            }
        }
    }
}

private final class FailingDeltaLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true
    private let chunks: [String]
    private let failure: ReadingAgentError

    init(chunks: [String], failure: ReadingAgentError) {
        self.chunks = chunks
        self.failure = failure
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        throw failure
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: chunk))]
                )))
            }
            continuation.finish(throwing: failure)
        }
    }
}

private final class SummaryToolCallLanguageModel: LanguageModel, @unchecked Sendable {
    let isAvailable = true

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        .toolCalls(Transcript.ToolCalls([
            Transcript.ToolCall(
                id: "unexpected-summary-tool",
                toolName: "providerCapabilityProbe",
                arguments: try GeneratedContent(json: "{}")
            ),
        ]))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class TransportOverflowSummaryLanguageModel: LanguageModel,
    @unchecked Sendable
{
    let isAvailable = true
    private let session: URLSession
    private let url: URL

    init(session: URLSession, url: URL) {
        self.session = session
        self.url = url
    }

    func supports(locale: Locale) -> Bool { true }

    func generate(
        transcript: Transcript,
        options: GenerationOptions?
    ) async throws -> Transcript.Entry {
        _ = try await session.data(from: url)
        return .response(Transcript.Response(
            assetIDs: [],
            segments: [.text(.init(content: "unreachable"))]
        ))
    }

    func stream(
        transcript: Transcript,
        options: GenerationOptions?
    ) -> AsyncThrowingStream<Transcript.Entry, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor StreamResponseOptionRecorder {
    private(set) var values: [Int?] = []

    func append(_ value: Int?) {
        values.append(value)
    }
}

private actor RuntimeLanguageModelState {
    private(set) var inputEntryCounts: [Int] = []
    private(set) var responseTokenLimits: [Int?] = []

    func record(inputEntryCount: Int, responseTokenLimit: Int?) {
        inputEntryCounts.append(inputEntryCount)
        responseTokenLimits.append(responseTokenLimit)
    }
}

private actor FinalCommitBarrier: AgentCommitInterlock {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func beforeFinalCommit(runID: String) async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiting = releaseWaiters
        releaseWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor ProviderBindingBarrier: AgentProviderBindingInterlock {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func beforeProviderBindingCheck(runID: String) async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SessionCancellationBarrier: AgentSessionCancellationInterlock {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func afterClockInvalidation() async {
        entered = true
        let currentEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        currentEntryWaiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        currentReleaseWaiters.forEach { $0.resume() }
    }
}

private actor NonCooperativeMissingSecretStore: ProviderSecretStore {
    private var secretRead = false
    private var released = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func save(secret: String, reference: String?) -> String {
        reference ?? "provider:non-cooperative-missing"
    }

    func secret(for reference: String) async -> String? {
        secretRead = true
        let currentReadWaiters = readWaiters
        readWaiters.removeAll()
        currentReadWaiters.forEach { $0.resume() }
        guard !released else { return nil }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return nil
    }

    func delete(reference: String) {}

    func waitUntilSecretRead() async {
        guard !secretRead else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseMissingSecret() {
        released = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        currentReleaseWaiters.forEach { $0.resume() }
    }
}

private actor FirstPersistedStartBarrier: AgentSessionStartInterlock {
    private var callCount = 0
    private var persistedFirstRunID: String?
    private var firstEntered = false
    private var firstReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func afterRunPersisted(runID: String) async {
        callCount += 1
        guard callCount == 1 else { return }
        persistedFirstRunID = runID
        firstEntered = true
        let currentEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        currentEntryWaiters.forEach { $0.resume() }
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilFirstEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseFirst() {
        firstReleased = true
        let currentReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        currentReleaseWaiters.forEach { $0.resume() }
    }

    func firstRunID() -> String? {
        persistedFirstRunID
    }
}

private actor SourceRefreshBarrier: SourceRevisionCommitInterlock {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func beforeSnapshotCommit(sourceID: String) async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor DriverContextCapture {
    private(set) var limits: AgentRuntimeLimits?

    func record(_ limits: AgentRuntimeLimits) {
        self.limits = limits
    }
}

private struct CapturingDriverFactory: ReadingAgentDriverFactory {
    let capture: DriverContextCapture

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        CapturingReadingAgentDriver(context: context, capture: capture)
    }
}

private struct CapturingReadingAgentDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let capture: DriverContextCapture

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        await capture.record(context.limits)
        _ = try await context.budget.consumeModelRound()
        return AgentModelResult(output: .scoutingSummary("captured"), usage: nil)
    }
}

private struct FakeDriverFactory: ReadingAgentDriverFactory {
    let counter: DriverInvocationCounter

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        FakeReadingAgentDriver(context: context, counter: counter)
    }
}

private struct FakeReadingAgentDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let counter: DriverInvocationCounter

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        await counter.increment()
        _ = try await context.budget.consumeModelRound()
        if request.request.goal == "slow" {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let arguments = GeneratedReadingToolArguments(
            sourceID: "",
            snapshotID: "",
            adapterID: "",
            locatorJSON: "",
            query: "",
            limit: 20,
            artifactID: "",
            offset: 0
        )
        _ = try await runtime.execute(tool: .listSources, arguments: arguments)
        let output = AgentStructuredOutput.scoutingSummary("fake grounded scout")
        let data = try JSONEncoder().encode(output)
        try await context.recorder.appendTranscript(role: .assistant, content: data)
        return AgentModelResult(output: output, usage: AgentTokenUsage(
            inputTokens: 10,
            outputTokens: 5
        ))
    }
}

private struct RejectingDriverFactory: ReadingAgentDriverFactory {
    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        RejectingReadingAgentDriver(context: context)
    }
}

private struct RejectingReadingAgentDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        return AgentModelResult(
            output: .scoutingSummary(""),
            usage: nil
        )
    }
}

private struct AdapterCandidateDriverFactory: ReadingAgentDriverFactory {
    let candidate: AdapterPlan

    func makeDriver(context: AgentDriverContext) -> any ReadingAgentModelDriver {
        AdapterCandidateDriver(context: context, candidate: candidate)
    }
}

private struct AdapterCandidateDriver: ReadingAgentModelDriver {
    let context: AgentDriverContext
    let candidate: AdapterPlan

    func generate(
        _ request: AgentModelRequest,
        runtime: ReadingToolRuntime,
        previousTranscript: Data?
    ) async throws -> AgentModelResult {
        _ = try await context.budget.consumeModelRound()
        return AgentModelResult(output: .adapterPlan(candidate), usage: nil)
    }
}

private func makeConfirmationCandidate(
    base: AdapterPlan,
    id: String,
    reason: String
) -> AdapterPlan {
    let fallback = QuickLookAdapter.id
    let auxiliary = Array(
        Set(base.auxiliaryAdapterIDs + [base.primaryAdapterID])
            .subtracting([fallback])
    ).sorted()
    return AdapterPlan(
        id: id,
        schemaVersion: base.schemaVersion,
        sourceID: base.sourceID,
        snapshotID: base.snapshotID,
        primaryAdapterID: fallback,
        auxiliaryAdapterIDs: auxiliary,
        capabilityRoutes: base.capabilityRoutes,
        evidence: base.evidence,
        // The host must ignore this model-supplied number and use the 0.1
        // deterministic Quick Look probe confidence instead.
        confidence: 0.99,
        reason: reason,
        isUserOverride: false,
        createdAt: .now
    )
}

private struct ControlledModelHarness {
    let model: ControlledLanguageModel
    let run: AgentRun
    let transcript: Transcript
    let eventStream: AsyncThrowingStream<AgentEvent, Error>
}

private func makeControlledModelHarness(
    fixture: SessionFixture,
    base: any LanguageModel,
    limits: AgentRuntimeLimits
) async throws -> ControlledModelHarness {
    let profile = try XCTUnwrap(
        fixture.database.providerProfile(forSpaceID: fixture.imported.space.id)
    )
    let manifest = try fixture.database.currentSnapshotManifest(
        spaceID: fixture.imported.space.id
    )
    let request = AgentRunRequest(
        spaceID: fixture.imported.space.id,
        task: .scoutSpace,
        expectedSnapshotIDs: Set(manifest.values),
        snapshotManifest: manifest
    )
    let durableGeneration = try fixture.database.fetchAgentSession(
        spaceID: fixture.imported.space.id
    )?.generation ?? 0
    let clock = AgentGenerationClock(initialGeneration: durableGeneration)
    let generation = await clock.begin()
    let run = AgentRun(
        id: UUID().uuidString.lowercased(),
        spaceID: fixture.imported.space.id,
        task: .scoutSpace,
        generation: generation,
        state: .queued,
        providerProfileID: profile.id,
        providerDestinationIdentity: try ProviderPolicy.destinationIdentity(profile),
        providerRevisionIdentity: try ProviderPolicy.revisionIdentity(profile),
        createdAt: .now,
        startedAt: nil,
        finishedAt: nil,
        errorCategory: nil
    )
    let queuedEvent = try fixture.database.beginAgentRun(run, request: request)
    try fixture.database.markAgentRunRunningCAS(
        id: run.id,
        spaceID: run.spaceID,
        generation: generation
    )
    let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream()
    let recorder = AgentEventRecorder(
        database: fixture.database,
        runID: run.id,
        continuation: pair.continuation
    )
    try await recorder.publishPersisted(queuedEvent)
    let budget = AgentRunBudget(limits: limits)
    let model = ControlledLanguageModel(
        base: base,
        transportLease: nil,
        profile: profile,
        database: fixture.database,
        spaceID: run.spaceID,
        runID: run.id,
        generation: generation,
        limits: limits,
        clock: clock,
        budget: budget,
        recorder: recorder,
        telemetry: AgentModelTelemetry()
    )
    let transcript = Transcript(entries: [
        .prompt(Transcript.Prompt(
            id: "stream-request",
            segments: [.text(.init(content: "Return a bounded stream."))]
        )),
    ])
    return ControlledModelHarness(
        model: model,
        run: run,
        transcript: transcript,
        eventStream: pair.stream
    )
}

private func cancelHarnessAndBeginReplacement(
    fixture: SessionFixture,
    harness: ControlledModelHarness
) async throws -> AgentRun {
    _ = try fixture.database.transitionAgentRunIfActive(
        runID: harness.run.id,
        generation: harness.run.generation,
        allowedStates: [.running],
        finalState: .cancelled,
        errorCategory: "cancelled",
        kind: .cancelled,
        phase: "test",
        message: "cancelled before non-cooperative Provider return"
    )
    await harness.model.clock.invalidate()
    await harness.model.recorder.finish()

    let manifest = try fixture.database.currentSnapshotManifest(
        spaceID: harness.run.spaceID
    )
    let request = AgentRunRequest(
        spaceID: harness.run.spaceID,
        task: .scoutSpace,
        expectedSnapshotIDs: Set(manifest.values),
        snapshotManifest: manifest
    )
    let profile = harness.model.profile
    let replacement = AgentRun(
        id: UUID().uuidString.lowercased(),
        spaceID: harness.run.spaceID,
        task: .scoutSpace,
        generation: harness.run.generation + 1,
        state: .queued,
        providerProfileID: profile.id,
        providerDestinationIdentity: try ProviderPolicy.destinationIdentity(profile),
        providerRevisionIdentity: try ProviderPolicy.revisionIdentity(profile),
        createdAt: .now,
        startedAt: nil,
        finishedAt: nil,
        errorCategory: nil
    )
    try fixture.database.beginAgentRun(replacement, request: request)
    return replacement
}

private func responseText(in entry: Transcript.Entry) -> String {
    guard case .response(let response) = entry else { return "" }
    return response.segments.reduce(into: "") { result, segment in
        switch segment {
        case .text(let text), .reasoning(let text):
            result += text.content
        case .structure(let structure):
            result += structure.content.text
        case .image:
            break
        }
    }
}

private struct SessionFixture {
    let root: URL
    let inputRoot: URL
    let database: LibraryDatabase
    let imported: ManagedImportResult
    let toolHost: ReadingToolHost
    let validator: AgentOutputValidator
    let secrets: InMemoryProviderSecretStore

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: inputRoot)
    }
}

private func makeSessionFixture(providerKind: ProviderKind) async throws -> SessionFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OneReader-AgentSession-\(UUID().uuidString)", isDirectory: true)
    let inputRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("OneReader-AgentSessionInput-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
    let input = inputRoot.appendingPathComponent("book.md")
    try Data("# Session\n\nEvidence.\n".utf8).write(to: input)
    let database = try LibraryDatabase(rootURL: root)
    let library = try ManagedLibrary(
        database: database,
        storagePolicy: LibraryStoragePolicy(
            largeImportThreshold: .max,
            minimumFreeCapacity: 0,
            capacityProvider: { _ in .max }
        )
    )
    let imported = try await library.importLocalSource(at: input)
    let registry = try AdapterRegistry.standard()
    let coordinator = AdapterCoordinator(database: database, registry: registry)
    _ = try await coordinator.prepare(
        sourceID: imported.source.id,
        snapshotID: imported.snapshot.id
    )
    let toolHost = ReadingToolHost(
        database: database,
        coordinator: coordinator,
        registry: registry
    )
    let secrets = InMemoryProviderSecretStore()
    let reference: String?
    if providerKind.requiresSecret {
        reference = await secrets.save(secret: "test-secret", reference: nil)
    } else {
        reference = nil
    }
    let profile = ProviderProfile(
        displayName: "Fake provider",
        kind: providerKind,
        endpoint: providerKind == .openAIResponses || providerKind == .anthropicMessages
            ? URL(string: "https://example.invalid/v1")
            : URL(string: "http://127.0.0.1:11434"),
        modelID: "fake-model",
        keychainReference: reference,
        isDefault: true,
        capabilities: [.connection, .structuredGeneration, .toolCalling]
    )
    try database.saveProviderProfile(profile)
    return SessionFixture(
        root: root,
        inputRoot: inputRoot,
        database: database,
        imported: imported,
        toolHost: toolHost,
        validator: AgentOutputValidator(database: database, registry: registry),
        secrets: secrets
    )
}
