import Foundation
import GRDB

actor LibraryCoordinator {
    nonisolated let root: URL
    private let dependencies: LibraryDependencies
    private let migrator: DatabaseMigrator
    private let snapshots = LibrarySnapshotService()
    private var database: DatabaseQueue?
    private var info: LibraryInfo?
    private var isPrepared = false

    init(
        root: URL,
        dependencies: LibraryDependencies = LibraryDependencies(),
        migrator: DatabaseMigrator = LibrarySchema.migrator
    ) {
        self.root = root
        self.dependencies = dependencies
        self.migrator = migrator
    }

    func open() throws -> LibraryInfo {
        if let info { return info }
        try Task.checkCancellation()
        if !isPrepared {
            try dependencies.prepareLibrary(root)
            isPrepared = true
        }
        let manager = FileManager.default
        let pointerURL = root.appending(path: "active-library.json")
        if !manager.fileExists(atPath: pointerURL.path) {
            if manager.fileExists(atPath: root.path) {
                try LibraryFiles.requireDirectory(root)
                guard try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
                    throw LibraryError.invalidLibrary(
                        "The active library pointer is missing. The existing files have been kept.")
                }
            }
            return try createLibrary()
        }

        try LibraryFiles.requireDirectory(root)
        let pointer = try LibraryFiles.read(ActiveLibrary.self, from: pointerURL)
        try LibraryFiles.validateVersion(pointer.formatVersion)
        try LibraryFiles.requireDirectory(root.appending(path: "generations"))
        let directory = LibraryFiles.generation(pointer.generationID, in: root)
        let manifest = try validateFiles(in: directory)
        let reader = try openDatabase(in: directory, readonly: true)
        defer { try? reader.close() }
        try validateDatabase(reader, manifest: manifest)
        let needsMigration = try reader.read { db in
            try !migrator.hasCompletedMigrations(db)
        }
        if needsMigration {
            return try upgrade(reader, directory: directory, manifest: manifest)
        }
        return try activate(pointer.generationID, manifest: manifest)
    }

    func close() throws {
        try database?.close()
        database = nil
        info = nil
    }

    func read<Value: Sendable>(
        _ query: @Sendable (Database) throws -> Value
    ) throws -> Value {
        guard let database else { throw LibraryError.notOpen }
        return try database.read(query)
    }

    func mutate<Value: Sendable>(
        _ mutation: @Sendable (Database, URL, LibraryDependencies) throws -> Value
    ) throws -> Value {
        guard let database, let info else { throw LibraryError.notOpen }
        try Task.checkCancellation()
        let originals = LibraryFiles.originals(
            in: LibraryFiles.generation(info.generationID, in: root))
        return try database.write { db in
            try mutation(db, originals, dependencies)
        }
    }

    func importOriginal(from source: URL, maximumByteCount: Int64) throws -> FileAsset {
        try importOriginal(from: source, maximumByteCount: maximumByteCount) { _, asset, _ in asset
        }
    }

    func importOriginal<Value: Sendable>(
        from source: URL, maximumByteCount: Int64,
        validate: @Sendable (URL, FileAsset) throws -> Void = { _, _ in },
        commit: @Sendable (Database, FileAsset, LibraryDependencies) throws -> Value
    ) throws -> Value {
        guard let database, let info else { throw LibraryError.notOpen }
        try Task.checkCancellation()
        try LibraryFiles.requireDirectory(root)
        let store = ManagedOriginals(
            generation: LibraryFiles.generation(info.generationID, in: root))
        try store.prepare()
        let id = dependencies.makeID()
        let staged = store.stagedURL(for: id)
        let original = try store.originalURL(for: ManagedOriginals.storageKey(id))
        guard !FileManager.default.fileExists(atPath: staged.path),
            !FileManager.default.fileExists(atPath: original.path),
            try database.read({ try FileAssetQueries.fetch(id, in: $0) }) == nil
        else { throw LibraryError.invalidLibrary("The generated original key already exists.") }
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        var committed: Value?
        do {
            let fingerprint = try store.copy(
                from: source, to: staged, maximumByteCount: maximumByteCount,
                checkpoint: dependencies.importCheckpoint)
            let asset = try store.validate(
                staged, id: id, originalFilename: source.lastPathComponent,
                byteCount: fingerprint.byteCount, sha256: fingerprint.sha256,
                importedAt: Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970))
            try validate(staged, asset)
            try Task.checkCancellation()
            try dependencies.importCheckpoint(.beforeRename)
            try store.publish(staged, as: original)
            try dependencies.importCheckpoint(.afterRename)
            try Task.checkCancellation()
            let value = try database.write { db in
                try asset.insert(db)
                let value = try commit(db, asset, dependencies)
                try dependencies.importCheckpoint(.beforeCommit)
                try Task.checkCancellation()
                return value
            }
            committed = value
            try dependencies.importCheckpoint(.afterCommit)
            return value
        } catch {
            if let committed { return committed }
            // If reference checking or removal fails, startup recovery retries it.
            if (try? dependencies.importCheckpoint(.beforeCleanup)) != nil {
                if let referenced = try? database.read({ try FileAssetQueries.fetchAll($0) }),
                    !referenced.contains(where: { $0.storageKey == original.lastPathComponent })
                {
                    try? FileManager.default.removeItem(at: original)
                    try? FileManager.default.removeItem(at: staged)
                }
            }
            throw error
        }
    }

    func originalURL(for id: UUID) throws -> URL {
        guard let database, let info else { throw LibraryError.notOpen }
        guard let asset = try database.read({ try FileAssetQueries.fetch(id, in: $0) }) else {
            throw LibraryError.invalidLibrary("This original is no longer available.")
        }
        try LibraryFiles.requireDirectory(root)
        let store = ManagedOriginals(
            generation: LibraryFiles.generation(info.generationID, in: root))
        try LibraryFiles.requireDirectory(store.generation.deletingLastPathComponent())
        try LibraryFiles.requireDirectory(store.generation)
        let original = try store.originalURL(for: asset.storageKey)
        try LibraryFiles.requireRegularFile(original)
        return original
    }

    func recoverImports() throws {
        guard let database, let info else { throw LibraryError.notOpen }
        try recoverImports(database, generationID: info.generationID)
    }

    private func recoverImports(_ database: DatabaseQueue, generationID: UUID) throws {
        try recoverImports(database, directory: LibraryFiles.generation(generationID, in: root))
    }

    private func recoverImports(_ database: DatabaseQueue, directory: URL) throws {
        try LibraryFiles.requireDirectory(root)
        let keys = try database.read { db -> Set<String>? in
            guard try db.tableExists("fileAsset") else { return nil }
            return try String.fetchSet(db, sql: "SELECT storageKey FROM fileAsset")
        }
        if let keys {
            let store = ManagedOriginals(generation: directory)
            try store.recover(referencedKeys: keys)
        }
    }

    func createSnapshot() throws -> LibrarySnapshot {
        guard let database, let info else { throw LibraryError.notOpen }
        return try snapshot(
            database, directory: LibraryFiles.generation(info.generationID, in: root))
    }

    func watchValues() throws -> AsyncValueObservation<[WatchRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(WatchQueries.fetchAll).values(in: database)
    }

    func caliberValues() throws -> AsyncValueObservation<[CaliberRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(CaliberQueries.fetchAll).values(in: database)
    }

    func jobValues() throws -> AsyncValueObservation<[JobRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(JobQueries.fetchAll).values(in: database)
    }

    func noteValues() throws -> AsyncValueObservation<[NoteRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(NoteQueries.fetchAll).values(in: database)
    }

    func taskValues() throws -> AsyncValueObservation<[JobTaskRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(JobTaskQueries.fetchAll).values(in: database)
    }

    func referenceValues() throws -> AsyncValueObservation<[LibraryItem]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking { db in
            try LibraryItem.fetchAll(
                db, sql: "SELECT * FROM libraryItem WHERE kind = 'Link' ORDER BY createdAt DESC, id"
            )
        }.values(in: database)
    }

    func photoValues() throws -> AsyncValueObservation<[PhotoRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(PhotoQueries.fetchAll).values(in: database)
    }

    func documentValues() throws -> AsyncValueObservation<[DocumentRecord]> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(DocumentQueries.fetchAll).values(in: database)
    }

    func benchValues() throws -> AsyncValueObservation<BenchSnapshot> {
        guard let database else { throw LibraryError.notOpen }
        return ValueObservation.tracking(BenchSnapshot.fetch).values(in: database)
    }

    private func createLibrary() throws -> LibraryInfo {
        let manager = FileManager.default
        let generationID = dependencies.makeID()
        let directory = LibraryFiles.generation(generationID, in: root)
        let manifest = LibraryManifest(
            formatVersion: LibraryManifest.currentVersion,
            libraryID: dependencies.makeID(),
            createdAt: dependencies.now()
        )
        try manager.createDirectory(
            at: LibraryFiles.originals(in: directory), withIntermediateDirectories: true)
        try LibraryFiles.write(manifest, to: directory.appending(path: "manifest.json"))
        let writer = try openDatabase(in: directory, readonly: false)
        do {
            try migrator.migrate(writer)
            try writer.write { db in
                try db.execute(
                    sql: "INSERT INTO libraryMetadata (id, createdAt) VALUES (?, ?)",
                    arguments: [
                        manifest.libraryID.uuidString, manifest.createdAt.timeIntervalSince1970,
                    ]
                )
            }
            try validateDatabase(writer, manifest: manifest)
            try recoverImports(writer, generationID: generationID)
            try Task.checkCancellation()
            try publish(generationID)
        } catch {
            try? writer.close()
            throw error
        }
        return install(writer, generationID: generationID, manifest: manifest)
    }

    private func upgrade(
        _ reader: DatabaseQueue, directory: URL, manifest: LibraryManifest
    ) throws -> LibraryInfo {
        let recovery = try snapshot(reader, directory: directory)
        let generationID = dependencies.makeID()
        let target = LibraryFiles.generation(generationID, in: root)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw LibraryError.invalidLibrary("The new library generation already exists.")
        }
        do {
            try FileManager.default.copyItem(at: recovery.directory, to: target)
            try FileManager.default.removeItem(at: target.appending(path: "snapshot.json"))
            let writer = try openDatabase(in: target, readonly: false)
            do {
                try migrator.migrate(writer)
                try validateDatabase(writer, manifest: manifest)
                try recoverImports(writer, generationID: generationID)
                try Task.checkCancellation()
                try reader.close()
                try publish(generationID)
            } catch {
                try? writer.close()
                throw error
            }
            return install(writer, generationID: generationID, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private func snapshot(_ database: DatabaseQueue, directory: URL) throws -> LibrarySnapshot {
        try recoverImports(database, directory: directory)
        let destination = root.appending(path: "recovery", directoryHint: .isDirectory)
            .appending(path: dependencies.makeID().uuidString, directoryHint: .isDirectory)
        return try snapshots.create(
            from: database, generation: directory, destination: destination,
            createdAt: dependencies.now()
        )
    }

    private func publish(_ generationID: UUID) throws {
        try LibraryFiles.write(
            ActiveLibrary(
                formatVersion: LibraryManifest.currentVersion, generationID: generationID),
            to: root.appending(path: "active-library.json")
        )
    }

    private func activate(_ generationID: UUID, manifest: LibraryManifest) throws -> LibraryInfo {
        let writer = try openDatabase(
            in: LibraryFiles.generation(generationID, in: root), readonly: false)
        do {
            try recoverImports(writer, generationID: generationID)
        } catch {
            try? writer.close()
            throw error
        }
        return install(writer, generationID: generationID, manifest: manifest)
    }

    private func install(
        _ writer: DatabaseQueue, generationID: UUID, manifest: LibraryManifest
    ) -> LibraryInfo {
        let info = LibraryInfo(generationID: generationID, manifest: manifest)
        database = writer
        self.info = info
        return info
    }

    private func validateFiles(in directory: URL) throws -> LibraryManifest {
        try LibraryFiles.requireDirectory(directory)
        try LibraryFiles.requireDirectory(LibraryFiles.originals(in: directory))
        try LibraryFiles.requireRegularFile(LibraryFiles.database(in: directory))
        let manifest = try LibraryFiles.read(
            LibraryManifest.self, from: directory.appending(path: "manifest.json"))
        try LibraryFiles.validateVersion(manifest.formatVersion)
        return manifest
    }

    private func openDatabase(in directory: URL, readonly: Bool) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.readonly = readonly
        return try DatabaseQueue(
            path: LibraryFiles.database(in: directory).path, configuration: configuration)
    }

    private func validateDatabase(_ database: DatabaseQueue, manifest: LibraryManifest) throws {
        try database.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                throw LibraryError.invalidLibrary(
                    "The library database failed its integrity check.")
            }
            try db.checkForeignKeys()
            let applied = try migrator.appliedIdentifiers(db)
            let known = migrator.migrations
            guard applied == Set(known.prefix(applied.count)) else {
                throw LibraryError.unsupportedSchema
            }
            guard
                try String.fetchOne(db, sql: "SELECT id FROM libraryMetadata")
                    == manifest.libraryID.uuidString,
                try Double.fetchOne(db, sql: "SELECT createdAt FROM libraryMetadata")
                    == manifest.createdAt.timeIntervalSince1970,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryMetadata") == 1
            else {
                throw LibraryError.invalidLibrary(
                    "The library metadata does not match its manifest.")
            }
        }
    }
}
