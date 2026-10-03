import Foundation
import GRDB

nonisolated struct LibraryActivationService {
    let root: URL
    let dependencies: LibraryDependencies
    let migrator: DatabaseMigrator

    func validate(_ library: LibraryInfo, expectedCounts: [String: Int]? = nil) throws {
        try validate(
            directory: LibraryFiles.generation(library.generationID, in: root),
            library: library, expectedCounts: expectedCounts)
    }

    private func validate(
        directory: URL, library: LibraryInfo, expectedCounts: [String: Int]? = nil
    ) throws {
        try LibraryFiles.requireDirectory(directory)
        let manifest = try LibraryFiles.read(
            LibraryManifest.self, from: directory.appending(path: "manifest.json"))
        guard manifest == library.manifest else {
            throw LibraryError.invalidLibrary(
                "The staged library identity changed. Restore was stopped.")
        }
        try LibraryFiles.requireRegularFile(LibraryFiles.database(in: directory))
        let reader = try RestoreDatabase.open(in: directory, readonly: true)
        defer { try? reader.close() }
        let counts = try RestoreDatabase.validate(
            reader, library: manifest, migrations: migrator.migrations, migrator: migrator)
        if let expectedCounts, counts != expectedCounts {
            throw LibraryError.invalidLibrary(
                "The staged library records changed. Restore was stopped.")
        }
        let assets = try reader.read(RestoreDatabase.assets)
        try reader.close()
        try RestoreFiles.withDirectory(LibraryFiles.originals(in: directory), item: "originals") {
            originals in
            for asset in assets {
                guard ManagedOriginals.assetID(for: asset.storageKey) == asset.id else {
                    throw LibraryError.invalidLibrary("An original has an invalid storage key.")
                }
                try RestoreFiles.verify(
                    SnapshotFile(
                        path: "originals/\(asset.storageKey)", byteCount: asset.byteCount,
                        sha256: asset.sha256),
                    name: asset.storageKey, in: originals)
            }
        }
    }

    func createRecovery(from database: DatabaseQueue, current: LibraryInfo) throws
        -> LibrarySnapshot
    {
        let generation = LibraryFiles.generation(current.generationID, in: root)
        var bytes = try database.read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let product = pages.multipliedReportingOverflow(by: size)
            guard !product.overflow else {
                throw LibraryError.invalidLibrary("The recovery size is too large.")
            }
            return product.partialValue
        }
        for original in try LibraryFiles.originalFiles(in: LibraryFiles.originals(in: generation)) {
            let size = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let sum = bytes.addingReportingOverflow(Int64(size))
            guard !sum.overflow else {
                throw LibraryError.invalidLibrary("The recovery size is too large.")
            }
            bytes = sum.partialValue
        }
        guard try dependencies.restoreAvailableCapacity(root) >= bytes else {
            throw LibraryError.invalidLibrary(
                "There is not enough free disk space for the recovery copy.")
        }
        let destination = root.appending(path: "recovery", directoryHint: .isDirectory)
            .appending(path: dependencies.makeID().uuidString, directoryHint: .isDirectory)
        let snapshot = try LibrarySnapshotService().create(
            from: database, generation: generation, destination: destination,
            createdAt: dependencies.now(),
            checkpoint: dependencies.backupCheckpoint)
        try validate(directory: snapshot.directory, library: current)
        return snapshot
    }
}
