import GRDB

nonisolated enum LibrarySchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-library-metadata", foreignKeyChecks: .immediate) { db in
            try db.create(table: "libraryMetadata") { table in
                table.column("id", .text).primaryKey()
                table.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v2-watches", foreignKeyChecks: .immediate) { db in
            try db.create(table: "watch") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().check(sql: "length(trim(name)) > 0")
                for column in [
                    "brand", "model", "caseReference", "serial", "approximateYear", "caseMaterial",
                    "waterResistance", "specificationNotes",
                ] {
                    table.column(column, .text)
                }
                table.column("caseDiameter", .double).check { $0 > 0 }
                table.column("lugWidth", .double).check { $0 > 0 }
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
        }
        migrator.registerMigration("v3-calibers", foreignKeyChecks: .immediate) { db in
            try db.create(table: "caliber") { table in
                table.column("id", .text).primaryKey()
                table.column("designation", .text).notNull()
                    .check(sql: "length(trim(designation)) > 0")
                for column in ["manufacturer", "variant", "specificationNotes", "sourceNote"] {
                    table.column(column, .text)
                }
                table.column("movementType", .text).notNull()
                    .check(
                        sql: "movementType IN ('Unknown', 'Manual', 'Automatic', 'Quartz', 'Other')"
                    )
                for column in ["beatRate", "liftAngle"] {
                    table.column(column, .double).check { $0 > 0 }
                        .check { $0 <= Double.greatestFiniteMagnitude }
                }
                for column in ["jewelCount", "powerReserve"] {
                    table.column(column, .double).check { $0 >= 0 }
                        .check { $0 <= Double.greatestFiniteMagnitude }
                }
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
            try db.alter(table: "watch") { table in
                table.add(column: "caliberID", .text).references("caliber", onDelete: .restrict)
            }
            try db.create(index: "watch_caliberID", on: "watch", columns: ["caliberID"])
        }
        migrator.registerMigration("v4-jobs", foreignKeyChecks: .immediate) { db in
            try db.create(table: "job") { table in
                table.column("id", .text).primaryKey()
                table.column("watchID", .text).notNull().references("watch", onDelete: .restrict)
                table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
                table.column("stage", .text).notNull().check(
                    sql:
                        "stage IN ('Planned', 'In progress', 'Waiting', 'Ready', 'Completed', 'Cancelled')"
                )
                for column in [
                    "reportedProblem", "agreedScope", "intakeCondition", "ownerName", "ownerEmail",
                    "ownerPhone",
                ] { table.column(column, .text) }
                table.column("intakeSnapshot", .text).notNull().check(
                    sql: "json_valid(intakeSnapshot)")
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
            try db.create(index: "job_watchID", on: "job", columns: ["watchID"])
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX job_one_open_per_watch ON job(watchID)
                    WHERE stage IN ('Planned', 'In progress', 'Waiting', 'Ready')
                    """)
        }
        migrator.registerMigration("v5-job-stages", foreignKeyChecks: .immediate) { db in
            try db.alter(table: "watch") { table in
                table.add(column: "condition", .text).notNull().defaults(to: "Unknown")
                    .check(
                        sql:
                            "condition IN ('Unknown', 'Running', 'Running poorly', 'Stopped', 'Disassembled')"
                    )
                table.add(column: "conditionNote", .text)
            }
            try db.alter(table: "job") { table in
                for column in ["waitingReason", "outcome", "recommendations", "cancellationReason"]
                {
                    table.add(column: column, .text)
                }
                for column in ["startedAt", "completedAt", "cancelledAt"] {
                    table.add(column: column, .double)
                }
            }
            try db.create(table: "activityEvent") { table in
                table.column("id", .text).primaryKey()
                table.column("jobID", .text).notNull().references("job", onDelete: .restrict)
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('Job stage changed', 'Watch condition changed')")
                table.column("occurredAt", .double).notNull()
                table.column("ordering", .integer).notNull().unique().check { $0 > 0 }
                for column in ["priorValue", "nextValue"] {
                    table.column(column, .text).notNull().check(sql: "json_valid(\(column))")
                }
            }
            try db.create(
                index: "activityEvent_jobID_ordering", on: "activityEvent",
                columns: ["jobID", "ordering"])
        }
        migrator.registerMigration("v6-notes", foreignKeyChecks: .immediate) { db in
            try db.create(table: "note") { table in
                table.column("id", .text).primaryKey()
                table.column("watchID", .text).references("watch", onDelete: .restrict)
                table.column("jobID", .text).references("job", onDelete: .restrict)
                table.column("caliberID", .text).references("caliber", onDelete: .restrict)
                table.check(
                    sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1"
                )
                table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
                table.column("body", .text).notNull()
                table.column("kind", .text).notNull()
                    .check(sql: "kind IN ('Observation', 'Research', 'Work log', 'Measurement')")
                for column in ["occurredAt", "createdAt", "updatedAt"] {
                    table.column(column, .double).notNull()
                }
            }
            for owner in ["watchID", "jobID", "caliberID"] {
                try db.create(
                    index: "note_\(owner)_occurredAt", on: "note", columns: [owner, "occurredAt"])
            }
        }
        migrator.registerMigration("v7-library-links", foreignKeyChecks: .immediate) { db in
            try db.create(table: "libraryItem") { table in
                table.column("id", .text).primaryKey()
                table.column("watchID", .text).references("watch", onDelete: .restrict)
                table.column("jobID", .text).references("job", onDelete: .restrict)
                table.column("caliberID", .text).references("caliber", onDelete: .restrict)
                table.check(
                    sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1"
                )
                table.column("kind", .text).notNull().check(sql: "kind = 'Link'")
                table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
                table.column("sourceURL", .text).notNull()
                table.column("sourceDescription", .text).notNull()
                table.column("notes", .text).notNull()
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
            for owner in ["watchID", "jobID", "caliberID"] {
                try db.create(
                    index: "libraryItem_\(owner)_createdAt", on: "libraryItem",
                    columns: [owner, "createdAt"])
            }
        }
        migrator.registerMigration("v8-file-assets", foreignKeyChecks: .immediate) { db in
            try db.create(table: "fileAsset") { table in
                table.column("id", .text).primaryKey()
                table.column("storageKey", .text).notNull().unique()
                    .check(sql: "storageKey = id || '.original'")
                table.column("originalFilename", .text).notNull()
                table.column("detectedType", .text).notNull().check(
                    sql:
                        "detectedType IN ('public.jpeg', 'public.png', 'public.heic', 'com.adobe.pdf')"
                )
                table.column("byteCount", .integer).notNull().check { $0 > 0 }
                table.column("sha256", .text).notNull().check(
                    sql: "length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'")
                table.column("importedAt", .double).notNull()
                for column in ["pixelWidth", "pixelHeight"] {
                    table.column(column, .integer).check { $0 > 0 }
                }
                table.column("orientation", .integer).check(sql: "orientation BETWEEN 1 AND 8")
                table.check(
                    sql: """
                        (detectedType = 'com.adobe.pdf' AND pixelWidth IS NULL AND pixelHeight IS NULL
                            AND orientation IS NULL)
                        OR (detectedType != 'com.adobe.pdf' AND pixelWidth IS NOT NULL
                            AND pixelHeight IS NOT NULL AND orientation IS NOT NULL)
                        """)
            }
        }
        migrator.registerMigration("v9-photos", foreignKeyChecks: .immediate) { db in
            try db.create(table: "libraryItem_new") { table in
                table.column("id", .text).primaryKey()
                table.column("watchID", .text).references("watch", onDelete: .restrict)
                table.column("jobID", .text).references("job", onDelete: .restrict)
                table.column("caliberID", .text).references("caliber", onDelete: .restrict)
                table.check(
                    sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1"
                )
                table.column("kind", .text).notNull().check(sql: "kind IN ('Link', 'Photo')")
                table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
                for column in ["sourceURL", "sourceDescription", "notes"] {
                    table.column(column, .text).notNull()
                }
                for column in ["createdAt", "updatedAt"] {
                    table.column(column, .double).notNull()
                }
                table.column("fileAssetID", .text).references("fileAsset", onDelete: .restrict)
                table.column("photoStage", .text)
                table.column("caption", .text)
                table.check(
                    sql: """
                        (kind = 'Link' AND fileAssetID IS NULL AND photoStage IS NULL)
                        OR (kind = 'Photo' AND fileAssetID IS NOT NULL AND photoStage IS NOT NULL
                            AND photoStage IN ('Unclassified', 'Before', 'During', 'After'))
                        """)
            }
            try db.execute(
                sql: """
                    INSERT INTO libraryItem_new
                        (id, watchID, jobID, caliberID, kind, title, sourceURL, sourceDescription,
                         notes, createdAt, updatedAt)
                    SELECT id, watchID, jobID, caliberID, kind, title, sourceURL, sourceDescription,
                           notes, createdAt, updatedAt FROM libraryItem
                    """)
            try db.drop(table: "libraryItem")
            try db.rename(table: "libraryItem_new", to: "libraryItem")
            for owner in ["watchID", "jobID", "caliberID"] {
                try db.create(
                    index: "libraryItem_\(owner)_createdAt", on: "libraryItem",
                    columns: [owner, "createdAt"])
            }
            try db.alter(table: "watch") { table in
                table.add(column: "coverPhotoID", .text).references(
                    "libraryItem", onDelete: .setNull)
            }
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
        migrator.registerMigration("v10-documents", foreignKeyChecks: .deferred) { db in
            // Deferred checks preserve watch covers while replacing the referenced table.
            try db.execute(sql: "DROP TRIGGER watch_cover_insert")
            try db.execute(sql: "DROP TRIGGER watch_cover_update")
            try db.create(table: "libraryItem_new") { table in
                table.column("id", .text).primaryKey()
                table.column("watchID", .text).references("watch", onDelete: .restrict)
                table.column("jobID", .text).references("job", onDelete: .restrict)
                table.column("caliberID", .text).references("caliber", onDelete: .restrict)
                table.check(
                    sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1"
                )
                table.column("kind", .text).notNull().check(
                    sql: "kind IN ('Link', 'Photo', 'Document')")
                table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
                for column in ["sourceURL", "sourceDescription", "notes"] {
                    table.column(column, .text).notNull()
                }
                for column in ["createdAt", "updatedAt"] {
                    table.column(column, .double).notNull()
                }
                table.column("fileAssetID", .text).references("fileAsset", onDelete: .restrict)
                table.column("photoStage", .text)
                table.column("caption", .text)
                table.check(
                    sql: """
                        (kind = 'Link' AND fileAssetID IS NULL AND photoStage IS NULL)
                        OR (kind = 'Document' AND fileAssetID IS NOT NULL AND photoStage IS NULL)
                        OR (kind = 'Photo' AND fileAssetID IS NOT NULL AND photoStage IS NOT NULL
                            AND photoStage IN ('Unclassified', 'Before', 'During', 'After'))
                        """)
            }
            try db.execute(sql: "INSERT INTO libraryItem_new SELECT * FROM libraryItem")
            try db.drop(table: "libraryItem")
            try db.rename(table: "libraryItem_new", to: "libraryItem")
            for owner in ["watchID", "jobID", "caliberID"] {
                try db.create(
                    index: "libraryItem_\(owner)_createdAt", on: "libraryItem",
                    columns: [owner, "createdAt"])
            }
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
        return migrator
    }
}
