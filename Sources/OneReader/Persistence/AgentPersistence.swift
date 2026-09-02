import Foundation
import GRDB

struct PersistedAgentSession: Sendable {
    let spaceID: String
    let providerProfileID: String?
    let generation: Int
    let transcriptJSON: Data?
    let projectionJSON: Data?
    let updatedAt: Date
}

extension LibraryDatabase {
    func currentSnapshotManifest(spaceID: String) throws -> [String: String] {
        try pool.read { db in
            try Self.currentSnapshotManifest(db, spaceID: spaceID)
        }
    }

    func saveProviderProfile(_ profile: ProviderProfile) throws {
        let profile = try ProviderPolicy.normalizedProfile(profile)
        let capabilities = try AgentPersistenceCoder.encoder.encode(
            profile.capabilities.map(\.rawValue).sorted()
        )
        try pool.write { db in
            if profile.isDefault {
                try db.execute(
                    sql: "UPDATE provider_profiles SET is_default = 0 WHERE id != ?",
                    arguments: [profile.id]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO provider_profiles
                        (id, display_name, provider_kind, endpoint, model_id,
                         keychain_reference, is_default, created_at, updated_at,
                         context_window, timeout_seconds, capabilities_json,
                         last_tested_at, last_test_succeeded)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        provider_kind = excluded.provider_kind,
                        endpoint = excluded.endpoint,
                        model_id = excluded.model_id,
                        keychain_reference = excluded.keychain_reference,
                        is_default = excluded.is_default,
                        updated_at = excluded.updated_at,
                        context_window = excluded.context_window,
                        timeout_seconds = excluded.timeout_seconds,
                        capabilities_json = excluded.capabilities_json,
                        last_tested_at = excluded.last_tested_at,
                        last_test_succeeded = excluded.last_test_succeeded
                    """,
                arguments: [
                    profile.id,
                    profile.displayName,
                    profile.kind.rawValue,
                    profile.endpoint?.absoluteString,
                    profile.modelID,
                    profile.keychainReference,
                    profile.isDefault,
                    profile.createdAt,
                    profile.updatedAt,
                    profile.contextWindow,
                    profile.timeoutSeconds,
                    capabilities,
                    profile.lastTestedAt,
                    profile.lastTestSucceeded,
                ]
            )
            try Self.invalidateRunsWithStaleProviderBinding(db)
        }
    }

    func fetchProviderProfiles() throws -> [ProviderProfile] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM provider_profiles
                    ORDER BY is_default DESC, updated_at DESC, id
                    """
            ).map(Self.decodeProviderProfile)
        }
    }

    @discardableResult
    func recordProviderConnectionTest(_ result: ProviderConnectionTest) throws -> Bool {
        let capabilities = try AgentPersistenceCoder.encoder.encode(
            result.capabilities.map(\.rawValue).sorted()
        )
        return try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM provider_profiles WHERE id = ?",
                arguments: [result.profileID]
            ), try ProviderPolicy.revisionIdentity(
                try Self.decodeProviderProfile(row)
            ) == result.providerRevisionIdentity else {
                return false
            }
            try db.execute(
                sql: """
                    UPDATE provider_profiles
                    SET capabilities_json = ?,
                        last_tested_at = ?,
                        last_test_succeeded = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    capabilities,
                    result.testedAt,
                    result.succeeded,
                    result.testedAt,
                    result.profileID,
                ]
            )
            try Self.invalidateRunsWithStaleProviderBinding(db)
            return true
        }
    }

    func providerProfile(forSpaceID spaceID: String) throws -> ProviderProfile? {
        try pool.read { db in
            try Self.providerProfile(db, forSpaceID: spaceID)
        }
    }

    func setProviderOverride(profileID: String?, forSpaceID spaceID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM space_provider_overrides WHERE space_id = ?",
                arguments: [spaceID]
            )
            if let profileID {
                try db.execute(
                    sql: """
                        INSERT INTO space_provider_overrides
                            (space_id, provider_profile_id, updated_at)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [spaceID, profileID, Date.now]
                )
            }
            try Self.invalidateRunsWithStaleProviderBinding(db, spaceID: spaceID)
        }
    }

    func acknowledgeRemoteDisclosure(runID: String) throws {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT space_id, provider_profile_id, provider_destination_identity
                    FROM agent_runs
                    WHERE id = ? AND state IN ('waitingForUser', 'interrupted')
                    """,
                arguments: [runID]
            ),
            let spaceID: String = row["space_id"],
            let profileID: String = row["provider_profile_id"],
            let destinationIdentity: String = row["provider_destination_identity"] else {
                throw ReadingAgentError.disclosureRequired
            }
            try Self.insertDisclosure(
                db,
                spaceID: spaceID,
                profileID: profileID,
                destinationIdentity: destinationIdentity
            )
        }
    }

    func acknowledgeRemoteDisclosure(spaceID: String, profileID: String) throws {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM provider_profiles WHERE id = ?",
                arguments: [profileID]
            ) else {
                throw ReadingAgentError.providerUnavailable("profile-not-found")
            }
            let destinationIdentity = try ProviderPolicy.destinationIdentity(
                try Self.decodeProviderProfile(row)
            )
            try Self.insertDisclosure(
                db,
                spaceID: spaceID,
                profileID: profileID,
                destinationIdentity: destinationIdentity
            )
        }
    }

    func hasAcknowledgedRemoteDisclosure(spaceID: String, profileID: String) throws -> Bool {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM provider_profiles WHERE id = ?",
                arguments: [profileID]
            ) else { return false }
            let destinationIdentity = try ProviderPolicy.destinationIdentity(
                try Self.decodeProviderProfile(row)
            )
            return try Self.hasDisclosure(
                db,
                spaceID: spaceID,
                profileID: profileID,
                destinationIdentity: destinationIdentity
            )
        }
    }

    func hasAcknowledgedRemoteDisclosure(
        spaceID: String,
        profileID: String,
        destinationIdentity: String
    ) throws -> Bool {
        try pool.read { db in
            try Self.hasDisclosure(
                db,
                spaceID: spaceID,
                profileID: profileID,
                destinationIdentity: destinationIdentity
            )
        }
    }

    func requireProviderBindingCurrent(
        runID: String,
        spaceID: String,
        profileID: String,
        destinationIdentity: String,
        revisionIdentity: String
    ) throws {
        try pool.read { db in
            guard let run = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, provider_profile_id, provider_destination_identity,
                           provider_revision_identity
                    FROM agent_runs
                    WHERE id = ? AND space_id = ?
                    """,
                arguments: [runID, spaceID]
            ),
            let stateValue: String = run["state"],
            stateValue == AgentRunState.queued.rawValue
                || stateValue == AgentRunState.running.rawValue,
            let storedProfileID: String = run["provider_profile_id"],
            let storedDestination: String = run["provider_destination_identity"],
            let storedRevision: String = run["provider_revision_identity"],
            storedProfileID == profileID,
            storedDestination == destinationIdentity,
            storedRevision == revisionIdentity,
            let selected = try Self.providerProfile(db, forSpaceID: spaceID),
            selected.id == profileID,
            try ProviderPolicy.destinationIdentity(selected) == destinationIdentity,
            try ProviderPolicy.revisionIdentity(selected) == revisionIdentity else {
                throw ReadingAgentError.runNotCurrent
            }
        }
    }

    #if DEBUG
    func insertAgentRunForTesting(
        _ run: AgentRun,
        request: AgentRunRequest,
        resumedFrom: String? = nil
    ) throws {
        let requestJSON = try AgentPersistenceCoder.encoder.encode(request)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent_runs
                        (id, space_id, task, generation, state, provider_profile_id,
                         provider_destination_identity, provider_revision_identity,
                         created_at, started_at, finished_at, error_category,
                         request_json, resumed_from_run_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id,
                    run.spaceID,
                    run.task.rawValue,
                    run.generation,
                    run.state.rawValue,
                    run.providerProfileID,
                    run.providerDestinationIdentity,
                    run.providerRevisionIdentity,
                    run.createdAt,
                    run.startedAt,
                    run.finishedAt,
                    run.errorCategory,
                    requestJSON,
                    resumedFrom,
                ]
            )
        }
    }
    #endif

    @discardableResult
    func beginAgentRun(
        _ run: AgentRun,
        request: AgentRunRequest,
        resumedFrom: String? = nil
    ) throws -> AgentEvent {
        let requestJSON = try AgentPersistenceCoder.encoder.encode(request)
        return try pool.write { db in
            let manifest = try Self.currentSnapshotManifest(db, spaceID: run.spaceID)
            guard !manifest.isEmpty,
                  manifest == request.snapshotManifest,
                  Set(manifest.values) == request.expectedSnapshotIDs else {
                throw ReadingAgentError.validationRejected("snapshot-set-changed")
            }
            if let resumedFrom {
                guard let parent = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT state, error_category, provider_profile_id,
                               provider_destination_identity, provider_revision_identity
                        FROM agent_runs
                        WHERE id = ? AND space_id = ?
                        """,
                    arguments: [resumedFrom, run.spaceID]
                ) else {
                    throw ReadingAgentError.interrupted
                }
                let parentState: String = parent["state"]
                let parentCategory: String? = parent["error_category"]
                let resumable = parentState == AgentRunState.interrupted.rawValue
                    || (parentState == AgentRunState.waitingForUser.rawValue
                        && parentCategory == "disclosure-required")
                let alreadyResumed = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM agent_runs WHERE resumed_from_run_id = ?)",
                    arguments: [resumedFrom]
                ) ?? false
                guard resumable, !alreadyResumed else {
                    throw ReadingAgentError.interrupted
                }
                let parentProfileID: String? = parent["provider_profile_id"]
                let parentDestination: String? = parent["provider_destination_identity"]
                let parentRevision: String? = parent["provider_revision_identity"]
                guard parentProfileID == run.providerProfileID,
                      parentDestination == run.providerDestinationIdentity,
                      parentRevision == run.providerRevisionIdentity else {
                    throw ReadingAgentError.interrupted
                }
                if let outputKind = try String.fetchOne(
                    db,
                    sql: "SELECT kind FROM agent_outputs WHERE run_id = ? AND disposition = 'waitingForUser'",
                    arguments: [resumedFrom]
                ), outputKind == "adapterPlan" {
                    throw ReadingAgentError.interrupted
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO reading_agent_sessions
                        (space_id, provider_profile_id, generation, transcript_json,
                         projection_json, updated_at)
                    VALUES (?, ?, ?, NULL, NULL, ?)
                    ON CONFLICT(space_id) DO UPDATE SET
                        provider_profile_id = excluded.provider_profile_id,
                        generation = excluded.generation,
                        updated_at = excluded.updated_at
                    WHERE reading_agent_sessions.generation < excluded.generation
                    """,
                arguments: [run.spaceID, run.providerProfileID, run.generation, Date.now]
            )
            guard db.changesCount == 1 else {
                throw ReadingAgentError.runNotCurrent
            }
            let supersededRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM agent_runs
                    WHERE space_id = ? AND generation < ?
                      AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                      AND (? IS NULL OR id != ?)
                    ORDER BY created_at, id
                    """,
                arguments: [
                    run.spaceID,
                    run.generation,
                    resumedFrom,
                    resumedFrom,
                ]
            )
            for row in supersededRows {
                let oldRunID: String = row["id"]
                try db.execute(
                    sql: """
                        UPDATE agent_runs
                        SET state = 'cancelled', finished_at = ?, error_category = 'superseded'
                        WHERE id = ? AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                        """,
                    arguments: [Date.now, oldRunID]
                )
                try db.execute(
                    sql: "UPDATE agent_outputs SET disposition = 'superseded' WHERE run_id = ?",
                    arguments: [oldRunID]
                )
                let event = try Self.nextEvent(
                    db,
                    runID: oldRunID,
                    kind: .cancelled,
                    phase: "session",
                    message: "Reading Agent Run 已被新的任务取代。",
                    metadata: ["category": "superseded"]
                )
                try Self.insertEvent(event, into: db)
            }
            if let resumedFrom {
                try db.execute(
                    sql: """
                        UPDATE agent_runs
                        SET state = 'cancelled', finished_at = ?, error_category = 'resumed'
                        WHERE id = ? AND state IN ('interrupted', 'waitingForUser')
                        """,
                    arguments: [Date.now, resumedFrom]
                )
                guard db.changesCount == 1 else { throw ReadingAgentError.interrupted }
                try db.execute(
                    sql: "UPDATE agent_outputs SET disposition = 'resumed' WHERE run_id = ?",
                    arguments: [resumedFrom]
                )
                let event = try Self.nextEvent(
                    db,
                    runID: resumedFrom,
                    kind: .cancelled,
                    phase: "recovery",
                    message: "原 Run 已由显式恢复创建的新 Run 取代。",
                    metadata: ["category": "resumed", "childRunID": run.id]
                )
                try Self.insertEvent(event, into: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO agent_runs
                        (id, space_id, task, generation, state, provider_profile_id,
                         provider_destination_identity, provider_revision_identity,
                         created_at, started_at, finished_at, error_category,
                         request_json, resumed_from_run_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id,
                    run.spaceID,
                    run.task.rawValue,
                    run.generation,
                    run.state.rawValue,
                    run.providerProfileID,
                    run.providerDestinationIdentity,
                    run.providerRevisionIdentity,
                    run.createdAt,
                    run.startedAt,
                    run.finishedAt,
                    run.errorCategory,
                    requestJSON,
                    resumedFrom,
                ]
            )
            let queuedEvent = try Self.nextEvent(
                db,
                runID: run.id,
                kind: .queued,
                phase: "queue",
                message: "Reading Agent Run 已加入队列。",
                metadata: ["task": request.task.rawValue],
                createdAt: run.createdAt
            )
            try Self.insertEvent(queuedEvent, into: db)
            return queuedEvent
        }
    }

    func markAgentRunRunningCAS(
        id: String,
        spaceID: String,
        generation: Int,
        startedAt: Date = .now
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE agent_runs
                    SET state = 'running', started_at = ?, finished_at = NULL, error_category = NULL
                    WHERE id = ? AND space_id = ? AND generation = ? AND state = 'queued'
                      AND EXISTS(
                        SELECT 1 FROM reading_agent_sessions
                        WHERE space_id = ? AND generation = ?
                      )
                    """,
                arguments: [startedAt, id, spaceID, generation, spaceID, generation]
            )
            guard db.changesCount == 1 else { throw ReadingAgentError.runNotCurrent }
        }
    }

    @discardableResult
    func interruptIncompleteAgentRuns(at date: Date = .now) throws -> Int {
        try pool.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, error_category
                    FROM agent_runs
                    WHERE state IN ('queued', 'running', 'waitingForUser')
                    ORDER BY created_at, id
                    """
            )
            for row in rows {
                let runID: String = row["id"]
                let previousCategory: String? = row["error_category"]
                let category = previousCategory.map { "app-restart:\($0)" } ?? "app-restart"
                try db.execute(
                    sql: """
                        UPDATE agent_runs
                        SET state = 'interrupted', finished_at = ?, error_category = ?
                        WHERE id = ?
                        """,
                    arguments: [date, category, runID]
                )
                let event = try Self.nextEvent(
                    db,
                    runID: runID,
                    kind: .interrupted,
                    phase: "recovery",
                    message: "应用重新启动；未完成的 Reading Agent Run 已中断。",
                    metadata: ["category": category],
                    createdAt: date
                )
                try Self.insertEvent(event, into: db)
            }
            return rows.count
        }
    }

    func fetchAgentRuns(spaceID: String? = nil) throws -> [AgentRun] {
        try pool.read { db in
            let rows: [Row]
            if let spaceID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM agent_runs WHERE space_id = ? ORDER BY created_at DESC",
                    arguments: [spaceID]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM agent_runs ORDER BY created_at DESC")
            }
            return try rows.map(Self.decodeAgentRun)
        }
    }

    func agentRunState(runID: String) throws -> AgentRunState? {
        try pool.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT state FROM agent_runs WHERE id = ?",
                arguments: [runID]
            ) else { return nil }
            guard let state = AgentRunState(rawValue: raw) else {
                throw LibraryDatabaseError.corruptValue(
                    table: "agent_runs",
                    column: "state",
                    value: raw
                )
            }
            return state
        }
    }

    func request(forRunID runID: String) throws -> AgentRunRequest? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT request_json FROM agent_runs WHERE id = ?",
                arguments: [runID]
            ) else { return nil }
            return try AgentPersistenceCoder.decoder.decode(AgentRunRequest.self, from: data)
        }
    }

    func appendAgentEvent(_ event: AgentEvent) throws {
        try pool.write { db in
            let state = try String.fetchOne(
                db,
                sql: "SELECT state FROM agent_runs WHERE id = ?",
                arguments: [event.runID]
            )
            guard state == AgentRunState.queued.rawValue
                    || state == AgentRunState.running.rawValue else {
                throw ReadingAgentError.runNotCurrent
            }
            let nextSequence = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), -1) + 1 FROM agent_events WHERE run_id = ?",
                arguments: [event.runID]
            ) ?? 0
            guard event.sequence == nextSequence else {
                throw ReadingAgentError.runNotCurrent
            }
            try Self.insertEvent(event, into: db)
        }
    }

    func fetchAgentEvents(runID: String) throws -> [AgentEvent] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM agent_events WHERE run_id = ? ORDER BY sequence",
                arguments: [runID]
            ).map { row in
                let kindValue: String = row["kind"]
                guard let kind = AgentEventKind(rawValue: kindValue) else {
                    throw LibraryDatabaseError.corruptValue(
                        table: "agent_events",
                        column: "kind",
                        value: kindValue
                    )
                }
                let metadataData: Data = row["metadata_json"]
                return AgentEvent(
                    id: row["id"],
                    runID: row["run_id"],
                    sequence: row["sequence"],
                    kind: kind,
                    phase: row["phase"],
                    message: row["message"],
                    metadata: try AgentPersistenceCoder.decoder.decode(
                        [String: String].self,
                        from: metadataData
                    ),
                    createdAt: row["created_at"]
                )
            }
        }
    }

    @discardableResult
    func appendTranscriptRecord(
        runID: String,
        role: AgentTranscriptRole,
        disposition: AgentTranscriptDisposition,
        content: Data,
        createdAt: Date = .now
    ) throws -> AgentTranscriptRecord {
        try pool.write { db in
            try Self.insertTranscriptRecord(
                db,
                runID: runID,
                role: role,
                disposition: disposition,
                content: content,
                createdAt: createdAt
            )
        }
    }

    func fetchTranscriptRecords(runID: String) throws -> [AgentTranscriptRecord] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM agent_transcript_entries
                    WHERE run_id = ? ORDER BY sequence
                    """,
                arguments: [runID]
            ).map { row in
                let roleValue: String = row["role"]
                guard let role = AgentTranscriptRole(rawValue: roleValue) else {
                    throw LibraryDatabaseError.corruptValue(
                        table: "agent_transcript_entries",
                        column: "role",
                        value: roleValue
                    )
                }
                let dispositionValue: String = row["disposition"]
                guard let disposition = AgentTranscriptDisposition(
                    rawValue: dispositionValue
                ) else {
                    throw LibraryDatabaseError.corruptValue(
                        table: "agent_transcript_entries",
                        column: "disposition",
                        value: dispositionValue
                    )
                }
                return AgentTranscriptRecord(
                    id: row["id"],
                    runID: row["run_id"],
                    sequence: row["sequence"],
                    role: role,
                    disposition: disposition,
                    content: row["content"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func updateAgentSessionAndAppendContextCAS(
        spaceID: String,
        runID: String,
        providerProfileID: String?,
        generation: Int,
        transcriptJSON: Data,
        projectedTranscriptJSON: Data,
        projectionAuditJSON: Data
    ) throws {
        try pool.write { db in
            try Self.requireActiveGeneration(
                db,
                runID: runID,
                spaceID: spaceID,
                generation: generation,
                allowedStates: [.running]
            )
            try db.execute(
                sql: """
                    UPDATE reading_agent_sessions
                    SET provider_profile_id = ?, transcript_json = ?, projection_json = ?, updated_at = ?
                    WHERE space_id = ? AND generation = ?
                    """,
                arguments: [
                    providerProfileID,
                    transcriptJSON,
                    projectedTranscriptJSON,
                    Date.now,
                    spaceID,
                    generation,
                ]
            )
            guard db.changesCount == 1 else {
                throw ReadingAgentError.runNotCurrent
            }
            let sequence = try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(sequence), -1) + 1
                    FROM agent_context_snapshots WHERE run_id = ?
                    """,
                arguments: [runID]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO agent_context_snapshots
                        (id, run_id, sequence, full_transcript_json,
                         projected_transcript_json, projection_audit_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    runID,
                    sequence,
                    transcriptJSON,
                    projectedTranscriptJSON,
                    projectionAuditJSON,
                    Date.now,
                ]
            )
        }
    }

    func fetchAgentContextSnapshots(runID: String) throws -> [AgentContextSnapshot] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM agent_context_snapshots
                    WHERE run_id = ? ORDER BY sequence
                    """,
                arguments: [runID]
            ).map { row in
                AgentContextSnapshot(
                    id: row["id"],
                    runID: row["run_id"],
                    sequence: row["sequence"],
                    fullTranscriptJSON: row["full_transcript_json"],
                    projectedTranscriptJSON: row["projected_transcript_json"],
                    projectionAuditJSON: row["projection_audit_json"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    @discardableResult
    func appendAgentModelCallAudit(
        _ metric: AgentModelCallMetric,
        spaceID: String,
        generation: Int,
        partialRole: AgentTranscriptRole?,
        partialContent: Data?
    ) throws -> AgentModelCallMetric {
        try pool.write { db in
            let resolvedMetric = try Self.resolveModelCallAuditMetric(
                db,
                metric: metric,
                spaceID: spaceID,
                generation: generation
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_model_call_metrics
                        (id, run_id, round, kind, outcome, input_bytes, output_bytes,
                         input_token_upper_bound, output_token_upper_bound,
                         duration_milliseconds, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    resolvedMetric.id,
                    resolvedMetric.runID,
                    resolvedMetric.round,
                    resolvedMetric.kind.rawValue,
                    resolvedMetric.outcome.rawValue,
                    resolvedMetric.inputBytes,
                    resolvedMetric.outputBytes,
                    resolvedMetric.inputTokenUpperBound,
                    resolvedMetric.outputTokenUpperBound,
                    resolvedMetric.durationMilliseconds,
                    resolvedMetric.createdAt,
                ]
            )
            if resolvedMetric.outcome != .succeeded,
               let partialRole,
               let partialContent {
                _ = try Self.insertTranscriptRecord(
                    db,
                    runID: resolvedMetric.runID,
                    role: partialRole,
                    disposition: .partialFailure,
                    content: partialContent,
                    createdAt: resolvedMetric.createdAt
                )
            }
            return resolvedMetric
        }
    }

    func fetchAgentModelCallMetrics(runID: String) throws -> [AgentModelCallMetric] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM agent_model_call_metrics
                    WHERE run_id = ? ORDER BY round
                    """,
                arguments: [runID]
            ).map { row in
                let kindValue: String = row["kind"]
                guard let kind = AgentModelCallMetric.Kind(rawValue: kindValue) else {
                    throw LibraryDatabaseError.corruptValue(
                        table: "agent_model_call_metrics",
                        column: "kind",
                        value: kindValue
                    )
                }
                let outcomeValue: String = row["outcome"]
                guard let outcome = AgentModelCallMetric.Outcome(
                    rawValue: outcomeValue
                ) else {
                    throw LibraryDatabaseError.corruptValue(
                        table: "agent_model_call_metrics",
                        column: "outcome",
                        value: outcomeValue
                    )
                }
                return AgentModelCallMetric(
                    id: row["id"],
                    runID: row["run_id"],
                    round: row["round"],
                    kind: kind,
                    outcome: outcome,
                    inputBytes: row["input_bytes"],
                    outputBytes: row["output_bytes"],
                    inputTokenUpperBound: row["input_token_upper_bound"],
                    outputTokenUpperBound: row["output_token_upper_bound"],
                    durationMilliseconds: row["duration_milliseconds"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func fetchAgentSession(spaceID: String) throws -> PersistedAgentSession? {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM reading_agent_sessions WHERE space_id = ?",
                arguments: [spaceID]
            ).map { row in
                PersistedAgentSession(
                    spaceID: row["space_id"],
                    providerProfileID: row["provider_profile_id"],
                    generation: row["generation"],
                    transcriptJSON: row["transcript_json"],
                    projectionJSON: row["projection_json"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    func saveAgentArtifact(_ artifact: AgentArtifact) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent_artifacts
                        (id, run_id, digest, media_type, relative_path,
                         byte_count, summary, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    artifact.id,
                    artifact.runID,
                    artifact.digest,
                    artifact.mediaType,
                    artifact.relativePath,
                    artifact.byteCount,
                    artifact.summary,
                    artifact.createdAt,
                ]
            )
        }
    }

    func fetchAgentArtifacts(runID: String) throws -> [AgentArtifact] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM agent_artifacts WHERE run_id = ? ORDER BY created_at, id",
                arguments: [runID]
            ).map { row in
                AgentArtifact(
                    id: row["id"],
                    runID: row["run_id"],
                    digest: row["digest"],
                    mediaType: row["media_type"],
                    relativePath: row["relative_path"],
                    byteCount: row["byte_count"],
                    summary: row["summary"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func agentArtifact(id: String, runID: String) throws -> AgentArtifact? {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_artifacts WHERE id = ? AND run_id = ?",
                arguments: [id, runID]
            ).map { row in
                AgentArtifact(
                    id: row["id"],
                    runID: row["run_id"],
                    digest: row["digest"],
                    mediaType: row["media_type"],
                    relativePath: row["relative_path"],
                    byteCount: row["byte_count"],
                    summary: row["summary"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func agentOutput(runID: String) throws -> PersistedAgentOutput? {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_outputs WHERE run_id = ?",
                arguments: [runID]
            ).map { row in
                let payload: Data = row["payload_json"]
                return PersistedAgentOutput(
                    runID: row["run_id"],
                    kind: row["kind"],
                    output: try AgentPersistenceCoder.decoder.decode(
                        AgentStructuredOutput.self,
                        from: payload
                    ),
                    disposition: row["disposition"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    func hasObservation(for locator: Locator, containing quote: String? = nil) throws -> Bool {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT locator_json, body
                    FROM observations
                    WHERE source_id = ? AND snapshot_id = ? AND adapter_id = ?
                    """,
                arguments: [locator.sourceID, locator.snapshotID, locator.adapterID]
            )
            for row in rows {
                let locatorData: Data = row["locator_json"]
                let candidate = try AgentPersistenceCoder.decoder.decode(
                    Locator.self,
                    from: locatorData
                )
                guard candidate == locator else { continue }
                guard let quote else { return true }
                let body: String? = row["body"]
                if let body,
                   Data(body.utf8).range(of: Data(quote.utf8)) != nil {
                    return true
                }
            }
            return false
        }
    }

    func readingGraph(id: String) throws -> ReadingGraph? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT payload_json FROM reading_graphs WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try AgentPersistenceCoder.decoder.decode(ReadingGraph.self, from: data)
        }
    }

    func latestReadingGraph(spaceID: String) throws -> ReadingGraph? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload_json FROM reading_graphs
                    WHERE space_id = ? ORDER BY created_at DESC LIMIT 1
                    """,
                arguments: [spaceID]
            ) else { return nil }
            return try AgentPersistenceCoder.decoder.decode(ReadingGraph.self, from: data)
        }
    }

    func readingGraph(spaceID: String, version: String) throws -> ReadingGraph? {
        try pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload_json FROM reading_graphs
                    WHERE space_id = ? AND version = ?
                    ORDER BY created_at DESC LIMIT 1
                    """,
                arguments: [spaceID, version]
            ) else { return nil }
            return try AgentPersistenceCoder.decoder.decode(ReadingGraph.self, from: data)
        }
    }


    func finalizeAgentRun(
        runID: String,
        spaceID: String,
        generation: Int,
        manifest: [String: String],
        output: PersistedAgentOutput,
        finalState: AgentRunState,
        errorCategory: String?,
        mutation: AgentDomainMutation?,
        event: AgentEvent,
        allowedRunStates: Set<AgentRunState> = [.running]
    ) throws {
        guard output.runID == runID,
              event.runID == runID,
              finalState == .completed || finalState == .waitingForUser else {
            throw ReadingAgentError.validationRejected("agent-finalization-contract")
        }
        let outputPayload = try AgentPersistenceCoder.encoder.encode(output.output)
        let eventMetadata = try AgentPersistenceCoder.encoder.encode(event.metadata)
        try pool.write { db in
            try Self.requireActiveGeneration(
                db,
                runID: runID,
                spaceID: spaceID,
                generation: generation,
                allowedStates: allowedRunStates
            )
            try Self.requireManifest(db, manifest: manifest, spaceID: spaceID)
            if let mutation {
                try Self.apply(
                    mutation,
                    db: db,
                    spaceID: spaceID,
                    manifest: manifest
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO agent_outputs
                        (run_id, kind, payload_json, disposition, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO UPDATE SET
                        kind = excluded.kind,
                        payload_json = excluded.payload_json,
                        disposition = excluded.disposition,
                        created_at = excluded.created_at
                    """,
                arguments: [
                    runID,
                    output.kind,
                    outputPayload,
                    output.disposition,
                    output.createdAt,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE agent_runs
                    SET state = ?, finished_at = ?, error_category = ?
                    WHERE id = ? AND generation = ?
                    """,
                arguments: [
                    finalState.rawValue,
                    finalState == .completed ? event.createdAt : nil,
                    errorCategory,
                    runID,
                    generation,
                ]
            )
            guard db.changesCount == 1 else { throw ReadingAgentError.runNotCurrent }
            let nextSequence = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), -1) + 1 FROM agent_events WHERE run_id = ?",
                arguments: [runID]
            ) ?? 0
            guard nextSequence == event.sequence else {
                throw ReadingAgentError.validationRejected("agent-event-sequence")
            }
            try db.execute(
                sql: """
                    INSERT INTO agent_events
                        (id, run_id, sequence, kind, phase, message, metadata_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.id,
                    event.runID,
                    event.sequence,
                    event.kind.rawValue,
                    event.phase,
                    event.message,
                    eventMetadata,
                    event.createdAt,
                ]
            )
        }
    }

    @discardableResult
    func transitionAgentRunIfActive(
        runID: String,
        generation: Int,
        allowedStates: Set<AgentRunState>,
        finalState: AgentRunState,
        errorCategory: String,
        outputDisposition: String? = nil,
        kind: AgentEventKind,
        phase: String,
        message: String
    ) throws -> AgentEvent? {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT agent_runs.state AS state,
                           agent_runs.generation AS run_generation,
                           reading_agent_sessions.generation AS session_generation
                    FROM agent_runs
                    JOIN reading_agent_sessions
                      ON reading_agent_sessions.space_id = agent_runs.space_id
                    WHERE agent_runs.id = ?
                    """,
                arguments: [runID]
            ) else { return nil }
            let stateValue: String = row["state"]
            let storedGeneration: Int = row["run_generation"]
            let sessionGeneration: Int = row["session_generation"]
            guard let state = AgentRunState(rawValue: stateValue),
                  storedGeneration == generation,
                  sessionGeneration == generation,
                  allowedStates.contains(state) else { return nil }
            try db.execute(
                sql: """
                    UPDATE agent_runs
                    SET state = ?, finished_at = ?, error_category = ?
                    WHERE id = ? AND generation = ?
                    """,
                arguments: [
                    finalState.rawValue,
                    finalState == .waitingForUser ? nil : Date.now,
                    errorCategory,
                    runID,
                    generation,
                ]
            )
            if let outputDisposition {
                try db.execute(
                    sql: "UPDATE agent_outputs SET disposition = ? WHERE run_id = ?",
                    arguments: [outputDisposition, runID]
                )
            }
            let event = try Self.nextEvent(
                db,
                runID: runID,
                kind: kind,
                phase: phase,
                message: message,
                metadata: ["category": errorCategory]
            )
            try Self.insertEvent(event, into: db)
            return event
        }
    }

    private static func providerProfile(
        _ db: Database,
        forSpaceID spaceID: String
    ) throws -> ProviderProfile? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT provider_profiles.*
                FROM provider_profiles
                LEFT JOIN space_provider_overrides
                  ON space_provider_overrides.provider_profile_id = provider_profiles.id
                 AND space_provider_overrides.space_id = ?
                ORDER BY
                    CASE WHEN space_provider_overrides.space_id IS NOT NULL THEN 0
                         WHEN provider_profiles.is_default = 1 THEN 1
                         ELSE 2 END,
                    provider_profiles.updated_at DESC
                LIMIT 1
                """,
            arguments: [spaceID]
        )
        return try row.map(decodeProviderProfile)
    }

    private static func insertDisclosure(
        _ db: Database,
        spaceID: String,
        profileID: String,
        destinationIdentity: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO remote_provider_disclosures
                    (space_id, provider_profile_id, destination_identity, acknowledged_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(space_id, provider_profile_id) DO UPDATE SET
                    destination_identity = excluded.destination_identity,
                    acknowledged_at = excluded.acknowledged_at
                """,
            arguments: [spaceID, profileID, destinationIdentity, Date.now]
        )
    }

    private static func hasDisclosure(
        _ db: Database,
        spaceID: String,
        profileID: String,
        destinationIdentity: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM remote_provider_disclosures
                    WHERE space_id = ? AND provider_profile_id = ?
                      AND destination_identity = ?
                )
                """,
            arguments: [spaceID, profileID, destinationIdentity]
        ) ?? false
    }

    private static func invalidateRunsWithStaleProviderBinding(
        _ db: Database,
        spaceID restrictedSpaceID: String? = nil
    ) throws {
        let spaces: [String]
        if let restrictedSpaceID {
            spaces = [restrictedSpaceID]
        } else {
            spaces = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT space_id
                    FROM agent_runs
                    WHERE state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                    ORDER BY space_id
                    """
            )
        }
        for spaceID in spaces {
            let current = try providerProfile(db, forSpaceID: spaceID)
            let currentDestination = try current.map(ProviderPolicy.destinationIdentity)
            let currentRevision = try current.map(ProviderPolicy.revisionIdentity)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, provider_profile_id, provider_destination_identity,
                           provider_revision_identity
                    FROM agent_runs
                    WHERE space_id = ?
                      AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                    ORDER BY created_at, id
                    """,
                arguments: [spaceID]
            )
            var invalidated = false
            for row in rows {
                let runID: String = row["id"]
                let profileID: String? = row["provider_profile_id"]
                let destination: String? = row["provider_destination_identity"]
                let revision: String? = row["provider_revision_identity"]
                guard profileID != current?.id
                        || destination != currentDestination
                        || revision != currentRevision else { continue }
                invalidated = true
                try db.execute(
                    sql: """
                        UPDATE agent_runs
                        SET state = 'cancelled', finished_at = ?,
                            error_category = 'provider-configuration-changed'
                        WHERE id = ? AND state IN ('queued', 'running', 'waitingForUser', 'interrupted')
                        """,
                    arguments: [Date.now, runID]
                )
                try db.execute(
                    sql: "UPDATE agent_outputs SET disposition = 'superseded' WHERE run_id = ?",
                    arguments: [runID]
                )
                let event = try nextEvent(
                    db,
                    runID: runID,
                    kind: .cancelled,
                    phase: "provider",
                    message: "Provider 配置已变化；旧 Run 已取消。",
                    metadata: ["category": "provider-configuration-changed"]
                )
                try insertEvent(event, into: db)
            }
            if invalidated {
                try db.execute(
                    sql: """
                        UPDATE reading_agent_sessions
                        SET generation = generation + 1,
                            transcript_json = NULL,
                            projection_json = NULL,
                            updated_at = ?
                        WHERE space_id = ?
                        """,
                    arguments: [Date.now, spaceID]
                )
            }
        }
    }

    private static func decodeProviderProfile(_ row: Row) throws -> ProviderProfile {
        let kindValue: String = row["provider_kind"]
        guard let kind = ProviderKind(rawValue: kindValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "provider_profiles",
                column: "provider_kind",
                value: kindValue
            )
        }
        let data: Data = row["capabilities_json"]
        let rawCapabilities = try AgentPersistenceCoder.decoder.decode([String].self, from: data)
        let capabilities = Set(rawCapabilities.compactMap(ProviderCapability.init(rawValue:)))
        let endpointString: String? = row["endpoint"]
        return ProviderProfile(
            id: row["id"],
            displayName: row["display_name"],
            kind: kind,
            endpoint: endpointString.flatMap(URL.init(string:)),
            modelID: row["model_id"],
            keychainReference: row["keychain_reference"],
            isDefault: row["is_default"],
            contextWindow: row["context_window"],
            timeoutSeconds: row["timeout_seconds"],
            capabilities: capabilities,
            lastTestedAt: row["last_tested_at"],
            lastTestSucceeded: row["last_test_succeeded"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func decodeAgentRun(_ row: Row) throws -> AgentRun {
        let taskValue: String = row["task"]
        let stateValue: String = row["state"]
        guard let task = AgentTaskKind(rawValue: taskValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "agent_runs",
                column: "task",
                value: taskValue
            )
        }
        guard let state = AgentRunState(rawValue: stateValue) else {
            throw LibraryDatabaseError.corruptValue(
                table: "agent_runs",
                column: "state",
                value: stateValue
            )
        }
        return AgentRun(
            id: row["id"],
            spaceID: row["space_id"],
            task: task,
            generation: row["generation"],
            state: state,
            providerProfileID: row["provider_profile_id"],
            providerDestinationIdentity: row["provider_destination_identity"],
            providerRevisionIdentity: row["provider_revision_identity"],
            createdAt: row["created_at"],
            startedAt: row["started_at"],
            finishedAt: row["finished_at"],
            errorCategory: row["error_category"]
        )
    }

    private static func requireCurrentSnapshot(
        _ db: Database,
        sourceID: String,
        snapshotID: String,
        spaceID: String
    ) throws {
        let isCurrent = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM sources
                    JOIN space_sources ON space_sources.source_id = sources.id
                    WHERE sources.id = ?
                      AND sources.latest_snapshot_id = ?
                      AND sources.managed_state != 'removed'
                      AND space_sources.space_id = ?
                )
                """,
            arguments: [sourceID, snapshotID, spaceID]
        ) ?? false
        guard isCurrent else {
            throw ReadingAgentError.validationRejected("snapshot-not-current")
        }
    }

    private static func currentSnapshotManifest(
        _ db: Database,
        spaceID: String
    ) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT sources.id AS source_id, sources.latest_snapshot_id AS snapshot_id
                FROM space_sources
                JOIN sources ON sources.id = space_sources.source_id
                WHERE space_sources.space_id = ?
                  AND sources.managed_state = 'ready'
                  AND sources.latest_snapshot_id IS NOT NULL
                ORDER BY space_sources.position, sources.id
                """,
            arguments: [spaceID]
        )
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let sourceID: String = row["source_id"]
            let snapshotID: String = row["snapshot_id"]
            return (sourceID, snapshotID)
        })
    }

    private static func requireManifest(
        _ db: Database,
        manifest: [String: String],
        spaceID: String
    ) throws {
        guard !manifest.isEmpty,
              try currentSnapshotManifest(db, spaceID: spaceID) == manifest else {
            throw ReadingAgentError.runNotCurrent
        }
    }

    private static func insertTranscriptRecord(
        _ db: Database,
        runID: String,
        role: AgentTranscriptRole,
        disposition: AgentTranscriptDisposition,
        content: Data,
        createdAt: Date
    ) throws -> AgentTranscriptRecord {
        let sequence = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(sequence), -1) + 1
                FROM agent_transcript_entries WHERE run_id = ?
                """,
            arguments: [runID]
        ) ?? 0
        let record = AgentTranscriptRecord(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            sequence: sequence,
            role: role,
            disposition: disposition,
            content: content,
            createdAt: createdAt
        )
        try db.execute(
            sql: """
                INSERT INTO agent_transcript_entries
                    (id, run_id, sequence, role, disposition, content, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.id,
                record.runID,
                record.sequence,
                record.role.rawValue,
                record.disposition.rawValue,
                record.content,
                record.createdAt,
            ]
        )
        return record
    }

    private static func resolveModelCallAuditMetric(
        _ db: Database,
        metric: AgentModelCallMetric,
        spaceID: String,
        generation: Int
    ) throws -> AgentModelCallMetric {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT agent_runs.state AS state,
                       agent_runs.generation AS run_generation,
                       agent_runs.provider_profile_id AS provider_profile_id,
                       agent_runs.provider_destination_identity AS provider_destination_identity,
                       agent_runs.provider_revision_identity AS provider_revision_identity,
                       reading_agent_sessions.generation AS session_generation
                FROM agent_runs
                JOIN reading_agent_sessions
                  ON reading_agent_sessions.space_id = agent_runs.space_id
                WHERE agent_runs.id = ? AND agent_runs.space_id = ?
                """,
            arguments: [metric.runID, spaceID]
        ) else { throw ReadingAgentError.runNotCurrent }
        let stateValue: String = row["state"]
        let runGeneration: Int = row["run_generation"]
        let sessionGeneration: Int = row["session_generation"]
        guard let state = AgentRunState(rawValue: stateValue),
              runGeneration == generation else {
            throw ReadingAgentError.runNotCurrent
        }
        if state == .cancelled {
            // A non-cooperative Provider may return after the host has cancelled
            // this immutable Run and advanced the mutable session generation.
            // Resolve the observed call to cancellation inside this transaction
            // so no success/failure audit can race the terminal state.
            return AgentModelCallMetric(
                id: metric.id,
                runID: metric.runID,
                round: metric.round,
                kind: metric.kind,
                outcome: .cancelled,
                inputBytes: metric.inputBytes,
                outputBytes: metric.outputBytes,
                inputTokenUpperBound: metric.inputTokenUpperBound,
                outputTokenUpperBound: metric.outputTokenUpperBound,
                durationMilliseconds: metric.durationMilliseconds,
                createdAt: metric.createdAt
            )
        }
        let storedProfileID: String? = row["provider_profile_id"]
        let storedDestination: String? = row["provider_destination_identity"]
        let storedRevision: String? = row["provider_revision_identity"]
        let selectedProfile = try providerProfile(db, forSpaceID: spaceID)
        let selectedDestination = try selectedProfile.map(ProviderPolicy.destinationIdentity)
        let selectedRevision = try selectedProfile.map(ProviderPolicy.revisionIdentity)
        guard state == .running,
              sessionGeneration == generation,
              storedProfileID == selectedProfile?.id,
              storedDestination == selectedDestination,
              storedRevision == selectedRevision else {
            throw ReadingAgentError.runNotCurrent
        }
        return metric
    }

    private static func requireActiveGeneration(
        _ db: Database,
        runID: String,
        spaceID: String,
        generation: Int,
        allowedStates: Set<AgentRunState>
    ) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT agent_runs.state AS state,
                       agent_runs.generation AS run_generation,
                       reading_agent_sessions.generation AS session_generation
                FROM agent_runs
                JOIN reading_agent_sessions
                  ON reading_agent_sessions.space_id = agent_runs.space_id
                WHERE agent_runs.id = ? AND agent_runs.space_id = ?
                """,
            arguments: [runID, spaceID]
        ) else { throw ReadingAgentError.runNotCurrent }
        let stateValue: String = row["state"]
        let runGeneration: Int = row["run_generation"]
        let sessionGeneration: Int = row["session_generation"]
        guard let state = AgentRunState(rawValue: stateValue),
              allowedStates.contains(state),
              runGeneration == generation,
              sessionGeneration == generation else {
            throw ReadingAgentError.runNotCurrent
        }
    }

    private static func apply(
        _ mutation: AgentDomainMutation,
        db: Database,
        spaceID: String,
        manifest: [String: String]
    ) throws {
        switch mutation {
        case .adapterPlan(let plan):
            guard manifest[plan.sourceID] == plan.snapshotID else {
                throw ReadingAgentError.validationRejected("snapshot-not-current")
            }
            let payload = try AgentPersistenceCoder.encoder.encode(plan)
            try db.execute(
                sql: """
                    INSERT INTO adapter_plans
                        (id, source_id, snapshot_id, schema_version, payload_json,
                         confidence, is_user_override, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    plan.id,
                    plan.sourceID,
                    plan.snapshotID,
                    plan.schemaVersion,
                    payload,
                    plan.confidence,
                    plan.isUserOverride,
                    plan.createdAt,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO active_adapter_plans (snapshot_id, plan_id, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(snapshot_id) DO UPDATE SET
                        plan_id = excluded.plan_id,
                        updated_at = excluded.updated_at
                    """,
                arguments: [plan.snapshotID, plan.id, Date.now]
            )

        case .readingGraph(let graph, let expectedSnapshots):
            guard expectedSnapshots == manifest,
                  Dictionary(uniqueKeysWithValues: graph.sourceSnapshots.map {
                      ($0.sourceID, $0.id)
                  }) == manifest else {
                throw ReadingAgentError.validationRejected("snapshot-set-changed")
            }
            let payload = try AgentPersistenceCoder.encoder.encode(graph)
            try db.execute(
                sql: """
                    INSERT INTO reading_graphs
                        (id, space_id, version, payload_json, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [graph.id, spaceID, graph.version, payload, graph.generatedAt]
            )

        case .readingPlan(let draft, let expectedSnapshots):
            guard expectedSnapshots == manifest,
                  let graphRow = try Row.fetchOne(
                    db,
                    sql: "SELECT version, payload_json FROM reading_graphs WHERE id = ? AND space_id = ?",
                    arguments: [draft.graphID, spaceID]
                  ) else {
                throw ReadingAgentError.validationRejected("graph-not-found")
            }
            let graphVersion: String = graphRow["version"]
            let graphData: Data = graphRow["payload_json"]
            let graph = try AgentPersistenceCoder.decoder.decode(ReadingGraph.self, from: graphData)
            guard graphVersion == draft.graphVersion,
                  Dictionary(uniqueKeysWithValues: graph.sourceSnapshots.map {
                      ($0.sourceID, $0.id)
                  }) == manifest else {
                throw ReadingAgentError.validationRejected("snapshot-set-changed")
            }
            let payload = try AgentPersistenceCoder.encoder.encode(draft)
            try db.execute(
                sql: """
                    INSERT INTO reading_plans
                        (id, space_id, graph_id, graph_version, goal,
                         payload_json, is_frozen, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                arguments: [
                    draft.id,
                    spaceID,
                    draft.graphID,
                    draft.graphVersion,
                    draft.goal,
                    payload,
                    draft.createdAt,
                ]
            )
        }
    }

    private static func nextEvent(
        _ db: Database,
        runID: String,
        kind: AgentEventKind,
        phase: String,
        message: String,
        metadata: [String: String],
        createdAt: Date = .now
    ) throws -> AgentEvent {
        let sequence = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sequence), -1) + 1 FROM agent_events WHERE run_id = ?",
            arguments: [runID]
        ) ?? 0
        return AgentEvent(
            id: UUID().uuidString.lowercased(),
            runID: runID,
            sequence: sequence,
            kind: kind,
            phase: phase,
            message: message,
            metadata: AgentRedactor.metadata(metadata),
            createdAt: createdAt
        )
    }

    private static func insertEvent(_ event: AgentEvent, into db: Database) throws {
        let metadata = try AgentPersistenceCoder.encoder.encode(event.metadata)
        try db.execute(
            sql: """
                INSERT INTO agent_events
                    (id, run_id, sequence, kind, phase, message, metadata_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                event.id,
                event.runID,
                event.sequence,
                event.kind.rawValue,
                event.phase,
                event.message,
                metadata,
                event.createdAt,
            ]
        )
    }
}

private enum AgentPersistenceCoder {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
