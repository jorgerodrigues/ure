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
        return migrator
    }
}
