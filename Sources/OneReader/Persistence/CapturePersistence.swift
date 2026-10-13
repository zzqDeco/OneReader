import Foundation
import GRDB

extension LibraryDatabase {
    static func registerCaptureInboxMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11-capture-inbox") { db in
            try db.execute(sql: """
                ALTER TABLE reading_spaces ADD COLUMN organization_state TEXT NOT NULL DEFAULT 'reading'
                    CHECK (organization_state IN ('inbox', 'reading', 'read', 'archived'));
                CREATE TABLE capture_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    receipt_json BLOB NOT NULL,
                    phase TEXT NOT NULL CHECK (phase IN ('received', 'waitingForImport', 'importing', 'preparing', 'ready', 'failed', 'cancelled')),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    attempt_id TEXT,
                    error_message TEXT,
                    needs_confirmation INTEGER NOT NULL DEFAULT 0,
                    allow_large_import INTEGER NOT NULL DEFAULT 0,
                    source_id TEXT,
                    snapshot_id TEXT,
                    space_id TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );
                CREATE INDEX capture_jobs_phase ON capture_jobs(phase, created_at);
                UPDATE library_metadata SET value = '11' WHERE key = 'database_schema';
                """)
        }
    }

    func receiveCapture(_ receipt: CaptureReceipt, allowLargeImport: Bool = false) throws {
        try receipt.validate()
        try pool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM capture_jobs WHERE id = ?", arguments: [receipt.id]) {
                guard try Self.decodeCapture(row).receipt.describesSameContent(as: receipt) else { throw CaptureError.conflictingReceipt }
                return
            }
            try db.execute(sql: """
                INSERT INTO capture_jobs (id, receipt_json, phase, allow_large_import, created_at, updated_at)
                VALUES (?, ?, 'received', ?, ?, ?)
                """, arguments: [receipt.id, try JSONEncoder().encode(receipt), allowLargeImport, receipt.createdAt, Date.now])
        }
    }

    func captureJobs() throws -> [CaptureJob] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM capture_jobs ORDER BY created_at DESC, id")
                .map(Self.decodeCapture)
        }
    }

    func captureJob(_ id: String) throws -> CaptureJob? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM capture_jobs WHERE id = ?", arguments: [id])
                .map(Self.decodeCapture)
        }
    }

    /// Called once when the host runtime starts, never while its tasks are live.
    func recoverCaptureJobs() throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE capture_jobs SET phase = 'waitingForImport', attempt_id = NULL,
                    error_message = NULL, updated_at = ?
                WHERE phase IN ('received', 'importing', 'preparing')
                """, arguments: [Date.now])
        }
    }

    func claimCapture(_ id: String) throws -> CaptureImportContext? {
        try pool.write { db in
            let token = UUID().uuidString.lowercased()
            try db.execute(sql: """
                UPDATE capture_jobs SET phase = 'importing', attempt_id = ?,
                    attempt_count = attempt_count + 1, error_message = NULL, updated_at = ?
                WHERE id = ? AND phase IN ('received', 'waitingForImport')
                """, arguments: [token, Date.now, id])
            return db.changesCount == 1 ? CaptureImportContext(jobID: id, attemptID: token) : nil
        }
    }

    static func validateCaptureClaim(_ context: CaptureImportContext, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM capture_jobs WHERE id = ? AND attempt_id = ?
                AND phase IN ('importing', 'preparing'))
            """, arguments: [context.jobID, context.attemptID]) == true else {
            throw CaptureError.noLongerActive
        }
    }

    func validateCaptureClaim(_ context: CaptureImportContext) throws {
        try pool.read { try Self.validateCaptureClaim(context, in: $0) }
    }

    func finishCapture(_ context: CaptureImportContext, phase: CapturePhase, error: String? = nil, needsConfirmation: Bool = false) throws {
        try pool.write { db in
            try Self.validateCaptureClaim(context, in: db)
            try db.execute(sql: """
                UPDATE capture_jobs SET phase = ?, error_message = ?, needs_confirmation = ?,
                    attempt_id = NULL, updated_at = ? WHERE id = ? AND attempt_id = ?
                """, arguments: [phase.rawValue, error, needsConfirmation, Date.now, context.jobID, context.attemptID])
        }
    }

    func retryCapture(_ id: String, confirmLargeImport: Bool = false) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE capture_jobs SET phase = 'waitingForImport', error_message = NULL,
                    needs_confirmation = 0,
                    allow_large_import = CASE WHEN ? THEN 1 ELSE allow_large_import END,
                    updated_at = ?
                WHERE id = ? AND phase IN ('failed', 'cancelled')
                    AND (needs_confirmation = 0 OR ?)
                """, arguments: [confirmLargeImport, Date.now, id, confirmLargeImport])
        }
    }

    func cancelCapture(_ id: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE capture_jobs SET phase = 'cancelled', attempt_id = NULL,
                    error_message = NULL, updated_at = ?
                WHERE id = ? AND phase != 'ready'
                """, arguments: [Date.now, id])
        }
    }

    /// Organization is intentionally independent of progress, annotations and history.
    func setSpaceOrganization(_ state: SpaceOrganizationState, spaceIDs: Set<String>) throws {
        try pool.write { db in
            for id in spaceIDs {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)", arguments: [id]) == true else {
                    throw LibraryStorageError.missingSpace(id)
                }
                try db.execute(sql: "UPDATE reading_spaces SET organization_state = ?, updated_at = ? WHERE id = ?",
                               arguments: [state.rawValue, Date.now, id])
            }
        }
    }

    /// Add the captured source to an existing Space without rewriting any locator.
    /// Original Space membership and its annotations remain available.
    func organizeCaptures(_ ids: Set<String>, intoSpaceID: String) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reading_spaces WHERE id = ?)", arguments: [intoSpaceID]) == true else {
                throw LibraryStorageError.missingSpace(intoSpaceID)
            }
            for id in ids {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM capture_jobs WHERE id = ?", arguments: [id]) else { continue }
                let job = try Self.decodeCapture(row)
                guard let sourceID = job.sourceID,
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sources WHERE id = ? AND managed_state != 'removed')", arguments: [sourceID]) == true else { continue }
                let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM space_sources WHERE space_id = ?", arguments: [intoSpaceID]) ?? 0
                try db.execute(sql: """
                    INSERT OR IGNORE INTO space_sources (space_id, source_id, position, added_at) VALUES (?, ?, ?, ?)
                    """, arguments: [intoSpaceID, sourceID, position, Date.now])
                if let originalSpace = job.spaceID, originalSpace != intoSpaceID,
                   job.receipt.targetSpaceID == nil,
                   try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM space_sources WHERE space_id = ?", arguments: [originalSpace]) == 1 {
                    try db.execute(sql: """
                        UPDATE reading_spaces SET organization_state = 'archived', updated_at = ?
                        WHERE id = ? AND organization_state = 'inbox'
                        """, arguments: [Date.now, originalSpace])
                }
                try db.execute(sql: "UPDATE capture_jobs SET space_id = ?, updated_at = ? WHERE id = ?",
                               arguments: [intoSpaceID, Date.now, id])
            }
        }
    }

    private static func decodeCapture(_ row: Row) throws -> CaptureJob {
        let data: Data = row["receipt_json"]
        let receipt = try JSONDecoder().decode(CaptureReceipt.self, from: data)
        try receipt.validate()
        guard let phase = CapturePhase(rawValue: row["phase"]) else { throw CaptureError.invalidReceipt }
        return CaptureJob(
            receipt: receipt, phase: phase, attemptCount: row["attempt_count"],
            attemptID: row["attempt_id"], errorMessage: row["error_message"],
            requiresLargeImportConfirmation: row["needs_confirmation"],
            allowLargeImport: row["allow_large_import"], sourceID: row["source_id"],
            snapshotID: row["snapshot_id"], spaceID: row["space_id"], updatedAt: row["updated_at"]
        )
    }
}
