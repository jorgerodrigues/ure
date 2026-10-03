import Foundation
import GRDB

nonisolated enum RestoreDatabase {
    static func open(in directory: URL, readonly: Bool) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.readonly = readonly
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        return try DatabaseQueue(
            path: LibraryFiles.database(in: directory).path, configuration: configuration)
    }

    static func validate(
        _ reader: DatabaseQueue, library: LibraryManifest, migrations: [String],
        migrator: DatabaseMigrator
    ) throws -> [String: Int] {
        guard let last = migrations.last,
            migrations == Array(migrator.migrations.prefix(migrations.count))
        else { throw RestoreError.unsupportedSchema }
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try migrator.migrate(expected, upTo: last)
        let expectedSchema = try expected.read(schema)
        return try reader.read { db in
            guard try schema(db) == expectedSchema else {
                throw RestoreError.invalidItem(
                    "library.sqlite", "The database schema does not match.")
            }
            guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"] else {
                throw RestoreError.invalidItem("library.sqlite", "The integrity check failed.")
            }
            try db.checkForeignKeys()
            guard
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") == migrations
            else { throw RestoreError.unsupportedSchema }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryMetadata") == 1,
                try String.fetchOne(db, sql: "SELECT id FROM libraryMetadata")
                    == library.libraryID.uuidString,
                try Double.fetchOne(db, sql: "SELECT createdAt FROM libraryMetadata")
                    == library.createdAt.timeIntervalSince1970
            else {
                throw RestoreError.invalidItem(
                    "library.sqlite", "The library identity does not match.")
            }
            try validateRelationships(db)
            return try BackupQueries.counts(db)
        }
    }

    private static func schema(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT type || char(10) || name || char(10) || tbl_name || char(10) || sql
                FROM sqlite_schema WHERE sql IS NOT NULL
                ORDER BY type, name
                """)
    }

    static func assets(_ db: Database) throws -> [FileAsset] {
        if try db.tableExists("fileAsset") { return try FileAssetQueries.fetchAll(db) }
        return []
    }

    private static func validateRelationships(_ db: Database) throws {
        if try db.tableExists("taskPart") {
            try requireNoRows(
                db,
                sql: """
                    SELECT 1 FROM taskPart
                    JOIN jobTask ON jobTask.id = taskPart.taskID
                    JOIN partRequirement ON partRequirement.id = taskPart.partID
                    WHERE jobTask.jobID != partRequirement.jobID LIMIT 1
                    """, reason: "A task links to a part in another job.")
        }
        if try db.tableExists("watch"),
            try db.columns(in: "watch").contains(where: { $0.name == "coverPhotoID" })
        {
            try requireNoRows(
                db,
                sql: """
                    SELECT 1 FROM watch JOIN libraryItem ON libraryItem.id = watch.coverPhotoID
                    LEFT JOIN job ON job.id = libraryItem.jobID
                    WHERE libraryItem.kind != 'Photo'
                       OR NOT (COALESCE(libraryItem.watchID = watch.id, 0)
                               OR COALESCE(job.watchID = watch.id, 0)) LIMIT 1
                    """, reason: "A watch cover has an invalid photo owner.")
        }
        if try db.tableExists("libraryItem"),
            try db.columns(in: "libraryItem").contains(where: { $0.name == "fileAssetID" })
        {
            try requireNoRows(
                db,
                sql: """
                    SELECT 1 FROM libraryItem JOIN fileAsset ON fileAsset.id = libraryItem.fileAssetID
                    WHERE (libraryItem.kind = 'Photo' AND fileAsset.detectedType = 'com.adobe.pdf')
                       OR (libraryItem.kind = 'Document' AND fileAsset.detectedType != 'com.adobe.pdf')
                    LIMIT 1
                    """, reason: "A file item's kind does not match its original type.")
        }
    }

    private static func requireNoRows(_ db: Database, sql: String, reason: String) throws {
        guard try Int.fetchOne(db, sql: sql) == nil else {
            throw RestoreError.invalidItem("library.sqlite", reason)
        }
    }
}
