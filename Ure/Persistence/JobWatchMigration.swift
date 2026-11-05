import GRDB

// Before v25, every job belonged to a watch. A new job can now start without one, and it shows
// "No watch yet" until you pick its watch. SQLite can't drop a NOT NULL, so the job table is
// rebuilt with an optional watch. Every row keeps every value, so nothing typed changes.
nonisolated enum JobWatchMigration {
    static func allowJobsWithoutWatch(in db: Database) throws {
        // The watch cover triggers read the job table, so they go with it and come back after.
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.create(table: "job_new") { table in
            table.column("id", .text).primaryKey()
            table.column("watchID", .text).references("watch", onDelete: .restrict)
            table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
            table.column("stage", .text).notNull()
                .check(sql: "stage IN ('In progress', 'Waiting', 'Done')")
            table.column("problem", .text)
            table.column("waitingFor", .text)
            for column in ["createdAt", "updatedAt"] {
                table.column(column, .double).notNull()
            }
            table.column("doneAt", .double)
            table.column("searchKey", .text).notNull().defaults(to: "")
            table.column("archivedAt", .double)
            table.column("notes", .text).notNull().defaults(to: "")
            table.check(sql: "stage = 'Waiting' OR waitingFor IS NULL")
            table.check(sql: "(stage = 'Done') = (doneAt IS NOT NULL)")
        }
        try db.execute(
            sql: """
                INSERT INTO job_new
                    (id, watchID, title, stage, problem, waitingFor, createdAt, updatedAt, doneAt,
                     searchKey, archivedAt, notes)
                SELECT id, watchID, title, stage, problem, waitingFor, createdAt, updatedAt,
                    doneAt, searchKey, archivedAt, notes
                FROM job
                """)
        try db.drop(table: "job")
        try db.rename(table: "job_new", to: "job")
        try db.create(index: "job_watchID", on: "job", columns: ["watchID"])
        // SQLite treats each missing watch as distinct, so many jobs can wait for a watch while
        // each watch still has at most one open job.
        try db.execute(
            sql: """
                CREATE UNIQUE INDEX job_one_open_per_watch ON job(watchID)
                WHERE stage IN ('In progress', 'Waiting')
                """)
        try db.create(index: "job_searchKey", on: "job", columns: ["searchKey"])
        try db.create(index: "job_archivedAt", on: "job", columns: ["archivedAt"])
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(
                sql: """
                    CREATE TRIGGER watch_cover_\(operation.lowercased()) BEFORE \(operation) ON watch
                    WHEN NEW.coverPhotoID IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM libraryItem AS item
                        LEFT JOIN job ON job.id = item.jobID
                        WHERE item.id = NEW.coverPhotoID AND item.kind = 'Photo'
                          AND (item.watchID = NEW.id OR job.watchID = NEW.id))
                    BEGIN SELECT RAISE(ABORT, 'Invalid watch cover'); END
                    """)
        }
    }
}
