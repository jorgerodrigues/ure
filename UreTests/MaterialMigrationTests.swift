import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct MaterialMigrationTests {
    @Test
    func upgradeKeepsEveryItemAsMaterialAndWritesRemovedFieldsIntoNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let legacy = try LegacyMaterialFixture.create(at: fixture.root, sources: fixture)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let material = try await coordinator.read(MaterialQueries.fetchAll)
        #expect(Set(material.map(\.id)) == Set(LegacyMaterialFixture.items.map(\.id)))
        for item in LegacyMaterialFixture.items {
            let record = try #require(material.first { $0.id == item.id })
            #expect(record.item.owner == item.owner)
            #expect(record.item.kind.rawValue == item.kind)
            #expect(record.item.title == item.title)
            #expect(record.item.createdAt.timeIntervalSince1970 == item.createdAt)
            #expect(record.item.updatedAt.timeIntervalSince1970 == item.createdAt + 1)
            if item.kind == "Link" {
                #expect(record.item.url == item.sourceURL && record.item.fileAssetID == nil)
            } else {
                #expect(record.item.url == nil && record.asset?.id == item.assetID)
            }
        }

        let notes = RecordNotesService(coordinator: coordinator)
        for (owner, text) in LegacyMaterialFixture.expectedNotes {
            #expect(try await notes.text(for: owner) == text)
        }
        let stored = try await coordinator.read { db in
            (
                columns: try db.columns(in: "libraryItem").map(\.name),
                assets: try FileAssetQueries.fetchAll(db),
                cover: try WatchQueries.fetch(LegacyMaterialFixture.watchID, in: db)?.coverPhotoID,
                watchUpdatedAt: try Double.fetchOne(
                    db, sql: "SELECT updatedAt FROM watch WHERE id = ?",
                    arguments: [LegacyMaterialFixture.watchID.uuidString])
            )
        }
        #expect(
            stored.columns == [
                "id", "watchID", "jobID", "caliberID", "kind", "title", "url", "fileAssetID",
                "createdAt", "updatedAt", "searchKey",
            ])
        #expect(stored.assets == legacy.assets)
        #expect(stored.cover == LegacyMaterialFixture.coverID)
        #expect(stored.watchUpdatedAt == 12)

        for asset in legacy.assets where asset.id != LegacyMaterialFixture.missingAssetID {
            let original = try await coordinator.originalURL(for: asset.id)
            #expect(original.lastPathComponent == asset.storageKey)
            #expect(try Data(contentsOf: original) == legacy.bytes[asset.id])
        }
        await #expect(throws: (any Error).self) {
            try await coordinator.originalURL(for: LegacyMaterialFixture.missingAssetID)
        }

        #expect(
            try await coordinator.read { try SearchQueries.fetch("water marks", in: $0) }.map(
                \.recordID) == [LegacyMaterialFixture.watchID])
        #expect(
            Set(
                try await coordinator.read { try SearchQueries.fetch("Dial at intake", in: $0) }
                    .map(\.recordID))
                == [LegacyMaterialFixture.watchID, LegacyMaterialFixture.coverID])
        try await coordinator.close()

        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(try await reopened.read(MaterialQueries.fetchAll).count == material.count)
        #expect(try await reopened.read(FileAssetQueries.fetchAll) == legacy.assets)
        try await reopened.close()
    }

    @Test
    func backupMadeBeforeMaterialRestoresWithAllItsMaterial() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Replaced by the restore"
        _ = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
        let package = fixture.directory.appending(path: "before-material.watchbackup")
        let legacy = try LegacyMaterialFixture.package(at: package, sources: fixture)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v20-material"])
        #expect(staged.summary.counts["libraryItem"] == LegacyMaterialFixture.items.count - 1)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator

        let material = try await restored.read(MaterialQueries.fetchAll)
        let expected = LegacyMaterialFixture.items.filter {
            $0.assetID != LegacyMaterialFixture.missingAssetID
        }
        #expect(Set(material.map(\.id)) == Set(expected.map(\.id)))
        #expect(material.allSatisfy { $0.item.kind == .link || $0.asset != nil })
        for asset in legacy.assets {
            #expect(
                try Data(contentsOf: try await restored.originalURL(for: asset.id))
                    == legacy.bytes[asset.id])
        }
        let notes = RecordNotesService(coordinator: restored)
        #expect(
            try await notes.text(for: .watch(LegacyMaterialFixture.watchID))
                == LegacyMaterialFixture.expectedNotes[0].1)
        #expect(
            try await notes.text(for: .job(LegacyMaterialFixture.openJobID))
                == "Service started.\n")
        #expect(
            try await restored.read(WatchQueries.fetchAll).map(\.name).sorted()
                == ["Field watch", "Seamaster"])
        try await restored.close()
    }

    @Test
    func eachItemWritesOnlyTheValuesThatGo() {
        #expect(
            MaterialMigration.entry(
                kind: "Photo", title: "Dial", sourceURL: "", sourceDescription: "", notes: "",
                photoStage: "Unclassified", caption: "  \n") == nil)
        for stage in ["Before", "During", "After"] {
            #expect(
                MaterialMigration.entry(
                    kind: "Photo", title: "Dial", sourceURL: "", sourceDescription: "",
                    notes: "", photoStage: stage, caption: nil) == "Photo · Dial\nStage: \(stage)")
        }
        #expect(
            MaterialMigration.entry(
                kind: "Document", title: "Guide", sourceURL: "https://example.com/a.pdf",
                sourceDescription: "Catalogue", notes: "  Indented.\nSecond line.\n\n",
                photoStage: nil, caption: nil)
                == "PDF · Guide\nSource URL: https://example.com/a.pdf\n"
                + "Source description: Catalogue\nNotes:   Indented.\nSecond line.")
        #expect(
            MaterialMigration.entry(
                kind: "Link", title: "Listing", sourceURL: "https://example.com",
                sourceDescription: "",
                notes: "", photoStage: nil, caption: nil) == nil)
        #expect(MaterialMigration.appending(["A"], to: "") == "From the old record\n\nA")
        #expect(
            MaterialMigration.appending(["A"], to: "Text") == "Text\n\nFrom the old record\n\nA")
        #expect(
            MaterialMigration.appending(["A"], to: "Text\n") == "Text\n\nFrom the old record\n\nA")
        #expect(
            MaterialMigration.appending(["A", "B"], to: "Text\n\n")
                == "Text\n\nFrom the old record\n\nA\n\nB")
        #expect(MaterialMigration.appending([], to: "Text ") == "Text ")
    }
}

// Puts a current library back to the schema before v20, with the item fields that v20 drops.
nonisolated enum MaterialMigrationFixture {
    static func restoreItemFields(in db: Database) throws {
        let covers = try Row.fetchAll(
            db, sql: "SELECT id, coverPhotoID FROM watch WHERE coverPhotoID IS NOT NULL")
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.create(table: "libraryItem_new") { table in
            table.column("id", .text).primaryKey()
            table.column("watchID", .text).references("watch", onDelete: .restrict)
            table.column("jobID", .text).references("job", onDelete: .restrict)
            table.column("caliberID", .text).references("caliber", onDelete: .restrict)
            table.check(
                sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1")
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
        try db.execute(
            sql: """
                INSERT INTO libraryItem_new
                SELECT id, watchID, jobID, caliberID, kind, title, coalesce(url, ''), '', '',
                    createdAt, updatedAt, fileAssetID,
                    CASE WHEN kind = 'Photo' THEN 'Unclassified' END, NULL
                FROM libraryItem
                """)
        try db.drop(table: "libraryItem")
        try db.rename(table: "libraryItem_new", to: "libraryItem")
        for owner in ["watchID", "jobID", "caliberID"] {
            try db.create(
                index: "libraryItem_\(owner)_createdAt", on: "libraryItem",
                columns: [owner, "createdAt"])
        }
        try db.alter(table: "libraryItem") { table in
            table.add(column: "searchKey", .text).notNull().defaults(to: "")
        }
        try db.create(index: "libraryItem_searchKey", on: "libraryItem", columns: ["searchKey"])
        try SearchKey.backfill("libraryItem", fields: ["title", "caption"], in: db)
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
        for row in covers {
            let id: String = row["id"]
            let cover: String = row["coverPhotoID"]
            try db.execute(
                sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ?", arguments: [cover, id])
        }
        try db.drop(table: "removedFileAsset")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v20-material'")
    }
}

nonisolated enum PhotoMigrationFixture {
    static func removePhotos(in db: Database) throws {
        try JobTaskMigrationFixture.removeTasks(in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10-documents'")
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.execute(sql: "ALTER TABLE watch DROP COLUMN coverPhotoID")
        try db.execute(
            sql: """
                CREATE TABLE libraryItem_links (
                    id TEXT PRIMARY KEY, watchID TEXT REFERENCES watch(id), jobID TEXT REFERENCES job(id),
                    caliberID TEXT REFERENCES caliber(id), kind TEXT NOT NULL CHECK(kind = 'Link'),
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0), sourceURL TEXT NOT NULL,
                    sourceDescription TEXT NOT NULL, notes TEXT NOT NULL, createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    CHECK((watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1))
                """)
        try db.execute(
            sql: """
                INSERT INTO libraryItem_links SELECT id, watchID, jobID, caliberID, kind, title,
                    sourceURL, sourceDescription, notes, createdAt, updatedAt FROM libraryItem WHERE kind = 'Link'
                """)
        try db.drop(table: "libraryItem")
        try db.rename(table: "libraryItem_links", to: "libraryItem")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9-photos'")
    }
}

nonisolated enum ReferenceMigrationFixture {
    static func removeLinks(in db: Database) throws {
        try FileAssetMigrationFixture.removeAssets(in: db)
        try db.execute(sql: "DROP TABLE libraryItem")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7-library-links'")
    }
}

// A library and a backup package made by the schema before v20. Photos have every stage and
// captions, PDFs and links have source details and notes, and one photo's original is missing.
nonisolated enum LegacyMaterialFixture {
    static let caliberID = id(0x01)
    static let watchID = id(0x02)
    static let quietWatchID = id(0x03)
    static let openJobID = id(0x04)
    static let closedJobID = id(0x05)
    static let coverID = id(0x12)
    static let missingAssetID = id(0x23)
    private static let lastMigration = "v19-record-notes"

    struct Item {
        let id: UUID
        let owner: LibraryItemOwner
        let kind: String
        let title: String
        var assetID: UUID?
        var sourceURL = ""
        var sourceDescription = ""
        var notes = ""
        var photoStage: String?
        var caption: String?
        let createdAt: Double
    }

    struct Legacy {
        let assets: [FileAsset]
        let bytes: [UUID: Data]
    }

    static let items = [
        Item(
            id: id(0x11), owner: .caliber(caliberID), kind: "Document", title: "Service guide",
            assetID: id(0x22), sourceURL: "https://example.com/552.pdf",
            sourceDescription: "Cousins catalogue, p. 12",
            notes: "Use 9010 on the pallet stones.", createdAt: 10),
        Item(
            id: id(0x19), owner: .caliber(caliberID), kind: "Photo", title: "Train bridge",
            assetID: id(0x26), photoStage: "During", caption: "", createdAt: 11),
        Item(
            id: id(0x1A), owner: .caliber(caliberID), kind: "Link", title: "Caliber thread",
            sourceURL: "https://example.com/552", sourceDescription: "Forum thread",
            createdAt: 12),
        Item(
            id: coverID, owner: .watch(watchID), kind: "Photo", title: "Dial at intake",
            assetID: id(0x20), photoStage: "Before", caption: "Water marks under the crystal.",
            createdAt: 20),
        Item(
            id: id(0x13), owner: .watch(watchID), kind: "Photo", title: "Caseback",
            assetID: id(0x21), photoStage: "Unclassified", caption: "", createdAt: 21),
        Item(
            id: id(0x14), owner: .watch(watchID), kind: "Link", title: "Seller listing",
            sourceURL: "https://example.com/listing", createdAt: 22),
        Item(
            id: id(0x15), owner: .watch(watchID), kind: "Photo", title: "After polish",
            assetID: id(0x25), photoStage: "After", caption: "Two lines.\nSecond line.  \n",
            createdAt: 23),
        Item(
            id: id(0x16), owner: .job(openJobID), kind: "Photo", title: "Movement out",
            assetID: missingAssetID, photoStage: "During", caption: "Balance removed.",
            createdAt: 30),
        Item(
            id: id(0x17), owner: .job(openJobID), kind: "Document", title: "Timegrapher print",
            assetID: id(0x24), createdAt: 31),
        Item(
            id: id(0x18), owner: .job(closedJobID), kind: "Link", title: "Crystal supplier",
            sourceURL: "https://example.com/crystal", sourceDescription: "Supplier page",
            notes: "Ordered twice.", createdAt: 5),
    ]

    static let expectedNotes: [(LibraryItemOwner, String)] = [
        (
            .watch(watchID),
            "Bought at auction.\n\nFrom the old record\n\n"
                + "Photo · Dial at intake\nStage: Before\nCaption: Water marks under the crystal.\n\n"
                + "Photo · After polish\nStage: After\nCaption: Two lines.\nSecond line."
        ),
        (
            .job(openJobID),
            "Service started.\n\nFrom the old record\n\n"
                + "Photo · Movement out\nStage: During\nCaption: Balance removed."
        ),
        (
            .job(closedJobID),
            "From the old record\n\n"
                + "Link · Crystal supplier\nSource description: Supplier page\nNotes: Ordered twice."
        ),
        (
            .caliber(caliberID),
            "Shared caliber knowledge.\n\nFrom the old record\n\n"
                + "PDF · Service guide\nSource URL: https://example.com/552.pdf\n"
                + "Source description: Cousins catalogue, p. 12\n"
                + "Notes: Use 9010 on the pallet stones.\n\n"
                + "Photo · Train bridge\nStage: During\n\n"
                + "Link · Caliber thread\nSource description: Forum thread"
        ),
        (.watch(quietWatchID), ""),
    ]

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x34, last))
    }

    @discardableResult
    static func create(at root: URL, sources: ImportFixture) throws -> Legacy {
        let generationID = UUID()
        let generation = LibraryFiles.generation(generationID, in: root)
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: generation), withIntermediateDirectories: true)
        let legacy = try database(in: generation, sources: sources, includesMissing: true)
        try LibraryFiles.write(
            ActiveLibrary(
                formatVersion: LibraryManifest.currentVersion, generationID: generationID),
            to: root.appending(path: "active-library.json"))
        return legacy
    }

    static func package(at package: URL, sources: ImportFixture) throws -> Legacy {
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: package), withIntermediateDirectories: true)
        let legacy = try database(in: package, sources: sources, includesMissing: false)
        let reader = try DatabaseQueue(path: LibraryFiles.database(in: package).path)
        let counts = try reader.read(BackupQueries.counts)
        let library = try reader.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM libraryMetadata")
        }
        try reader.close()
        let migrations = LibrarySchema.migrator.migrations
        let lastIndex = try #require(migrations.firstIndex(of: lastMigration))
        let paths =
            ["library.sqlite", "manifest.json"]
            + legacy.assets.map { "originals/\($0.storageKey)" }
        try LibraryFiles.write(
            BackupManifest(
                formatVersion: BackupManifest.currentVersion,
                exportedAt: Date(timeIntervalSince1970: 1_792_000_000),
                libraryID: try #require(library.flatMap(UUID.init(uuidString:))),
                applicationVersion: "before W034", migrations: Array(migrations[...lastIndex]),
                counts: counts,
                files: try paths.map { try fingerprint(package.appending(path: $0), path: $0) }),
            to: package.appending(path: "backup.json"))
        return legacy
    }

    private static func database(
        in directory: URL, sources: ImportFixture, includesMissing: Bool
    ) throws -> Legacy {
        let manifest = LibraryManifest(
            formatVersion: LibraryManifest.currentVersion, libraryID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.25))
        try LibraryFiles.write(manifest, to: directory.appending(path: "manifest.json"))
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(
            path: LibraryFiles.database(in: directory).path, configuration: configuration)
        try LibrarySchema.migrator.migrate(database, upTo: lastMigration)
        let photo = try Data(contentsOf: sources.source(type: .png))
        let pdf = try Data(contentsOf: sources.source(type: .pdf))
        let kept = items.filter { includesMissing || $0.assetID != missingAssetID }
        var assets: [FileAsset] = []
        var bytes: [UUID: Data] = [:]
        for item in kept {
            guard let assetID = item.assetID else { continue }
            let data = item.kind == "Document" ? pdf : photo
            let isPDF = item.kind == "Document"
            let asset = FileAsset(
                id: assetID, storageKey: "\(assetID.uuidString).original",
                originalFilename: "\(item.title).\(isPDF ? "pdf" : "png")",
                detectedType: isPDF ? .pdf : .png, byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                importedAt: Date(timeIntervalSince1970: item.createdAt),
                pixelWidth: isPDF ? nil : 16, pixelHeight: isPDF ? nil : 12,
                orientation: isPDF ? nil : 6)
            assets.append(asset)
            if assetID != missingAssetID {
                try data.write(
                    to: LibraryFiles.originals(in: directory).appending(path: asset.storageKey))
                bytes[assetID] = data
            }
        }
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO libraryMetadata (id, createdAt) VALUES (?, ?)",
                arguments: [
                    manifest.libraryID.uuidString, manifest.createdAt.timeIntervalSince1970,
                ])
            try seedRecords(db)
            for asset in assets { try asset.insert(db) }
            for item in kept { try insert(item, in: db) }
            try db.execute(
                sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ?",
                arguments: [coverID.uuidString, watchID.uuidString])
            try SearchKey.backfill("libraryItem", fields: ["title", "caption"], in: db)
        }
        try database.close()
        return Legacy(assets: assets.sorted { $0.importedAt < $1.importedAt }, bytes: bytes)
    }

    private static func seedRecords(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO caliber (id, designation, manufacturer, movementType, notes, createdAt,
                    updatedAt)
                VALUES (?, '552', 'Omega', 'Automatic', 'Shared caliber knowledge.', 10, 11)
                """, arguments: [caliberID.uuidString])
        try db.execute(
            sql: """
                INSERT INTO watch (id, name, brand, caliberID, notes, createdAt, updatedAt)
                VALUES (?, 'Seamaster', 'Omega', ?, 'Bought at auction.', 10, 12),
                    (?, 'Field watch', NULL, NULL, '', 10, 13)
                """,
            arguments: [watchID.uuidString, caliberID.uuidString, quietWatchID.uuidString])
        let snapshot = try String(
            decoding: JSONEncoder().encode(
                JobIntakeSnapshot(
                    watchName: "Seamaster", brand: "Omega", model: nil, caseReference: nil,
                    serial: nil, caliberDesignation: "552", caliberVariant: nil)), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO job (id, watchID, title, stage, intakeSnapshot, notes, createdAt,
                    updatedAt)
                VALUES (?, ?, 'Full service', 'In progress', ?, ?, 20, 21),
                    (?, ?, 'New crystal', 'Completed', ?, '', 5, 6)
                """,
            arguments: [
                openJobID.uuidString, watchID.uuidString, snapshot, "Service started.\n",
                closedJobID.uuidString, watchID.uuidString, snapshot,
            ])
        for table in [SearchKey.Table.watch, .caliber, .job] {
            try SearchKey.backfill(table, in: db)
        }
    }

    private static func insert(_ item: Item, in db: Database) throws {
        let column: String
        let ownerID: UUID
        switch item.owner {
        case .watch(let id): (column, ownerID) = ("watchID", id)
        case .job(let id): (column, ownerID) = ("jobID", id)
        case .caliber(let id): (column, ownerID) = ("caliberID", id)
        }
        try db.execute(
            sql: """
                INSERT INTO libraryItem (id, \(column), kind, title, sourceURL, sourceDescription,
                    notes, createdAt, updatedAt, fileAssetID, photoStage, caption)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id.uuidString, ownerID.uuidString, item.kind, item.title, item.sourceURL,
                item.sourceDescription, item.notes, item.createdAt, item.createdAt + 1,
                item.assetID?.uuidString, item.photoStage, item.caption,
            ])
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
