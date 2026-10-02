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
        return migrator
    }
}
