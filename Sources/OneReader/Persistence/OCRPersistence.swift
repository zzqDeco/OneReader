import Foundation
import GRDB

extension LibraryDatabase {
    static func registerOCRMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-local-ocr") { db in
            try db.execute(sql: """
                CREATE TABLE ocr_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id),
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id),
                    state TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    updated_at DATETIME NOT NULL
                );
                CREATE TABLE ocr_job_pages (
                    job_id TEXT NOT NULL REFERENCES ocr_jobs(id),
                    page_index INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(job_id, page_index)
                );
                CREATE TABLE ocr_revisions (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES sources(id),
                    snapshot_id TEXT NOT NULL REFERENCES snapshots(id),
                    payload BLOB NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE ocr_active (
                    snapshot_id TEXT PRIMARY KEY NOT NULL REFERENCES snapshots(id),
                    revision_id TEXT NOT NULL REFERENCES ocr_revisions(id)
                );
                CREATE INDEX ocr_jobs_snapshot ON ocr_jobs(snapshot_id, updated_at);
                UPDATE library_metadata SET value = '14' WHERE key = 'database_schema';
                """)
        }
    }

    func interruptIncompleteOCRJobs() throws {
        try pool.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM ocr_jobs WHERE state = 'running'") {
                var job = try JSONDecoder().decode(OCRJob.self, from: row["payload"])
                job.state = .interrupted; job.updatedAt = .now
                try Self.writeOCRJob(job, db: db)
            }
        }
    }

    func startOCRJob(_ job: OCRJob) throws {
        guard !job.engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.invalidInput("识别任务未记录宿主引擎。")
        }
        guard !job.pageIndices.isEmpty, job.pageIndices.count <= OCRSettings.maximumPagesPerJob,
              job.pageIndices.allSatisfy({ $0 >= 0 }), Set(job.pageIndices).count == job.pageIndices.count else {
            throw OCRError.resourceLimit
        }
        try pool.write { db in
            try Self.validateOCRSource(job, db: db)
            // A newly requested job supersedes older workers, which cannot publish afterward.
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM ocr_jobs WHERE snapshot_id = ? AND state = 'running'", arguments: [job.snapshotID]) {
                var old = try JSONDecoder().decode(OCRJob.self, from: row["payload"])
                old.state = .interrupted; old.updatedAt = .now
                try Self.writeOCRJob(old, db: db)
            }
            try Self.writeOCRJob(job, db: db)
        }
    }

    func saveOCRPage(_ page: OCRPage, jobID: String) throws -> OCRJob {
        try page.validate()
        return try pool.write { db in
            var job = try Self.readOCRJob(jobID, db: db)
            try Self.validateOCRSource(job, db: db)
            guard job.state == .running, job.pageIndices.contains(page.pageIndex) else { throw OCRError.staleJob }
            // The engine's page metadata is untrusted. Bind it to the persisted host job
            // and the time this result was received, not to fields in the engine response.
            try Self.writeOCRPage(page.hostStamped(job: job, at: .now), job: &job, db: db)
            return job
        }
    }

    /// Reuses only authentic persisted draft pages. Carryover is not a new recognition:
    /// retain the original host stamp (or explicit legacy unknown), even on a new engine.
    func resumeOCRDraftPages(fromJobID: String, intoJobID: String) throws -> OCRJob {
        try pool.write { db in
            let previous = try Self.readOCRJob(fromJobID, db: db)
            var job = try Self.readOCRJob(intoJobID, db: db)
            try Self.validateOCRSource(previous, db: db)
            try Self.validateOCRSource(job, db: db)
            guard previous.id != job.id, job.state == .running,
                  [.interrupted, .cancelled, .partial, .failed].contains(previous.state),
                  previous.sourceID == job.sourceID, previous.snapshotID == job.snapshotID,
                  previous.settings == job.settings else { throw OCRError.staleJob }
            let rows = try Row.fetchAll(db,
                sql: "SELECT page_index, payload FROM ocr_job_pages WHERE job_id = ? ORDER BY page_index",
                arguments: [previous.id])
            for row in rows {
                let pageIndex: Int = row["page_index"]
                guard job.pageIndices.contains(pageIndex), !job.completedPages.contains(pageIndex) else { continue }
                guard previous.pageIndices.contains(pageIndex), previous.completedPages.contains(pageIndex) else {
                    throw OCRError.staleJob
                }
                let page = try JSONDecoder().decode(OCRPage.self, from: row["payload"])
                guard page.pageIndex == pageIndex else { throw OCRError.staleJob }
                try page.validate()
                try Self.writeOCRPage(page, job: &job, db: db)
            }
            return job
        }
    }

    func markOCRPageFailed(_ pageIndex: Int, jobID: String, reason: String = "识别失败") throws -> OCRJob {
        try pool.write { db in
            var job = try Self.readOCRJob(jobID, db: db)
            guard job.state == .running else { throw OCRError.staleJob }
            job.failedPages = Array(Set(job.failedPages + [pageIndex])).sorted(); job.updatedAt = .now
            job.failureReasons[pageIndex] = String(reason.prefix(1024))
            try Self.writeOCRJob(job, db: db)
            return job
        }
    }

    /// The only publication path. Revision and activation are atomic and generation checked.
    func finishOCRJob(_ jobID: String, state: OCRJobState) throws -> OCRRevision? {
        try pool.write { db in
            var job = try Self.readOCRJob(jobID, db: db)
            try Self.validateOCRSource(job, db: db)
            guard job.state == .running else { throw OCRError.staleJob }
            guard state != .running && state != .interrupted,
                  state != .completed || Set(job.completedPages) == Set(job.pageIndices) else {
                throw OCRError.invalidInput("识别覆盖未完成，不能标记为整份成功。")
            }
            var pages = try Self.activeOCRRevision(snapshotID: job.snapshotID, db: db)?.pages ?? []
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM ocr_job_pages WHERE job_id = ? ORDER BY page_index", arguments: [jobID])
            let newPages = try rows.map { try JSONDecoder().decode(OCRPage.self, from: $0["payload"]) }
            let replaced = Set(newPages.map(\.pageIndex))
            pages.removeAll { replaced.contains($0.pageIndex) }
            pages.append(contentsOf: newPages)
            pages.sort { $0.pageIndex < $1.pageIndex }
            job.state = state; job.updatedAt = .now
            try Self.writeOCRJob(job, db: db)
            guard !newPages.isEmpty else { return nil }
            let revision = OCRRevision(id: UUID().uuidString.lowercased(), sourceID: job.sourceID,
                snapshotID: job.snapshotID, jobID: job.id, engineVersion: job.engineVersion,
                settings: job.settings, pages: pages, createdAt: .now)
            let encoded = try JSONEncoder().encode(revision)
            guard encoded.count <= OCRSettings.maximumRevisionBytes else { throw OCRError.resourceLimit }
            try db.execute(sql: "INSERT INTO ocr_revisions VALUES (?, ?, ?, ?, ?)",
                           arguments: [revision.id, revision.sourceID, revision.snapshotID, encoded, revision.createdAt])
            try db.execute(sql: "INSERT OR REPLACE INTO ocr_active VALUES (?, ?)", arguments: [job.snapshotID, revision.id])
            // Prevent a late index worker from publishing old-plan / new-OCR mixed evidence,
            // including the crash window before the new deterministic plan is installed.
            try db.execute(sql: "DELETE FROM active_adapter_plans WHERE snapshot_id = ?", arguments: [job.snapshotID])
            return revision
        }
    }

    func activeOCRRevision(snapshotID: String) throws -> OCRRevision? {
        try pool.read { try Self.activeOCRRevision(snapshotID: snapshotID, db: $0) }
    }

    func abandonOCRJob(_ id: String) throws {
        try pool.write { db in
            var job = try Self.readOCRJob(id, db: db)
            guard job.state == .running else { return }
            job.state = .failed; job.updatedAt = .now
            try Self.writeOCRJob(job, db: db)
        }
    }

    func ocrRevision(id: String, sourceID: String, snapshotID: String) throws -> OCRRevision? {
        try pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM ocr_revisions WHERE id = ? AND source_id = ? AND snapshot_id = ?", arguments: [id, sourceID, snapshotID]) else { return nil }
            return try JSONDecoder().decode(OCRRevision.self, from: data)
        }
    }

    func ocrJobs(snapshotID: String) throws -> [OCRJob] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM ocr_jobs WHERE snapshot_id = ? ORDER BY updated_at DESC", arguments: [snapshotID])
                .map { try JSONDecoder().decode(OCRJob.self, from: $0["payload"]) }
        }
    }

    func ocrDraftPages(jobID: String) throws -> [OCRPage] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM ocr_job_pages WHERE job_id = ? ORDER BY page_index", arguments: [jobID])
                .map { try JSONDecoder().decode(OCRPage.self, from: $0["payload"]) }
        }
    }

    func ocrRevisions(snapshotID: String) throws -> [OCRRevision] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM ocr_revisions WHERE snapshot_id = ? ORDER BY created_at DESC", arguments: [snapshotID])
                .map { try JSONDecoder().decode(OCRRevision.self, from: $0["payload"]) }
        }
    }

    func selectOCRRevision(_ id: String, snapshotID: String) throws {
        try pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_revisions r JOIN sources s ON s.id = r.source_id WHERE r.id = ? AND r.snapshot_id = ? AND s.latest_snapshot_id = ? AND s.managed_state != 'removed'", arguments: [id, snapshotID, snapshotID]) == 1 else { throw OCRError.missingRevision }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_jobs WHERE snapshot_id = ? AND state = 'running'", arguments: [snapshotID]) == 0 else { throw OCRError.staleJob }
            try db.execute(sql: "INSERT OR REPLACE INTO ocr_active VALUES (?, ?)", arguments: [snapshotID, id])
            try db.execute(sql: "DELETE FROM active_adapter_plans WHERE snapshot_id = ?", arguments: [snapshotID])
        }
    }

    private static func activeOCRRevision(snapshotID: String, db: Database) throws -> OCRRevision? {
        guard let data = try Data.fetchOne(db, sql: "SELECT r.payload FROM ocr_revisions r JOIN ocr_active a ON a.revision_id = r.id WHERE a.snapshot_id = ?", arguments: [snapshotID]) else { return nil }
        return try JSONDecoder().decode(OCRRevision.self, from: data)
    }

    private static func validateOCRSource(_ job: OCRJob, db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sources WHERE id = ? AND latest_snapshot_id = ? AND managed_state != 'removed'", arguments: [job.sourceID, job.snapshotID]) == 1 else { throw OCRError.staleJob }
    }

    private static func readOCRJob(_ id: String, db: Database) throws -> OCRJob {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM ocr_jobs WHERE id = ?", arguments: [id]) else { throw OCRError.staleJob }
        return try JSONDecoder().decode(OCRJob.self, from: data)
    }

    private static func writeOCRJob(_ job: OCRJob, db: Database) throws {
        try db.execute(sql: "INSERT INTO ocr_jobs (id, source_id, snapshot_id, state, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, payload = excluded.payload, updated_at = excluded.updated_at",
            arguments: [job.id, job.sourceID, job.snapshotID, job.state.rawValue, try JSONEncoder().encode(job), job.updatedAt])
    }

    private static func writeOCRPage(_ page: OCRPage, job: inout OCRJob, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO ocr_job_pages VALUES (?, ?, ?)",
                       arguments: [job.id, page.pageIndex, try JSONEncoder().encode(page)])
        job.completedPages = Array(Set(job.completedPages + [page.pageIndex])).sorted()
        job.updatedAt = .now
        try writeOCRJob(job, db: db)
    }
}
