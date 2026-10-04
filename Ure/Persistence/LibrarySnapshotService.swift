import CryptoKit
import Darwin
import Foundation
import GRDB

nonisolated struct LibrarySnapshotService {
    func create(
        from database: DatabaseQueue,
        generation: URL,
        destination: URL,
        createdAt: Date,
        exportingVersion: String? = nil,
        progress: @Sendable (BackupProgress) -> Void = { _ in },
        checkpoint: @Sendable (BackupCheckpoint) throws -> Void = { _ in }
    ) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging: URL
        let cleanup: URL
        if exportingVersion != nil {
            cleanup = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
                create: true)
            staging = cleanup.appending(
                path: destination.lastPathComponent, directoryHint: .isDirectory)
        } else {
            staging = destination.deletingLastPathComponent()
                .appending(
                    path: ".incomplete-\(UUID().uuidString)", directoryHint: .isDirectory)
            cleanup = staging
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: cleanup) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let sourceOriginals = LibraryFiles.originals(in: generation)
            let targetOriginals = LibraryFiles.originals(in: staging)
            try manager.createDirectory(at: targetOriginals, withIntermediateDirectories: false)

            progress(.database)
            let destinationDatabase = try DatabaseQueue(
                path: LibraryFiles.database(in: staging).path)
            defer { try? destinationDatabase.close() }
            try database.backup(to: destinationDatabase)
            try destinationDatabase.read { db in
                try db.checkForeignKeys()
                guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                    throw LibraryError.invalidLibrary("The recovery database failed validation.")
                }
            }
            let assets: [FileAsset]
            let counts: [String: Int]
            let migrations: [String]
            if exportingVersion != nil {
                (assets, counts, migrations) = try destinationDatabase.read { db in
                    (
                        try FileAssetQueries.fetchAll(db), try BackupQueries.counts(db),
                        try String.fetchAll(
                            db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                    )
                }
            } else {
                assets = []
                counts = [:]
                migrations = []
            }
            try destinationDatabase.writeWithoutTransaction { db in
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete"
                else {
                    throw LibraryError.invalidLibrary("The snapshot could not leave WAL mode.")
                }
            }
            try destinationDatabase.close()
            let sharedMemory = staging.appending(path: "library.sqlite-shm")
            if manager.fileExists(atPath: sharedMemory.path) {
                try manager.removeItem(at: sharedMemory)
            }
            try checkpoint(.copiedDatabase)

            let sourceManifest = generation.appending(path: "manifest.json")
            try LibraryFiles.requireRegularFile(sourceManifest)
            try manager.copyItem(at: sourceManifest, to: staging.appending(path: "manifest.json"))
            let originals: [URL]
            if exportingVersion != nil {
                let store = ManagedOriginals(generation: generation)
                originals = try assets.map { try store.originalURL(for: $0.storageKey) }
            } else {
                originals = try LibraryFiles.originalFiles(in: sourceOriginals)
            }
            progress(.originals(completed: 0, total: originals.count))
            for (index, original) in originals.enumerated() {
                try Task.checkCancellation()
                let relativePath = try LibraryFiles.relativePath(original, in: sourceOriginals)
                let target = targetOriginals.appending(path: relativePath)
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if exportingVersion != nil {
                    let asset = assets[index]
                    let copied = try ManagedOriginals(generation: generation).copy(
                        from: original, to: target, maximumByteCount: asset.byteCount,
                        checkpoint: { _ in try checkpoint(.copiedChunk) })
                    guard copied.byteCount == asset.byteCount, copied.sha256 == asset.sha256 else {
                        throw LibraryError.invalidLibrary(
                            "An original does not match its saved size or hash. The backup was not exported."
                        )
                    }
                } else {
                    try manager.copyItem(at: original, to: target)
                }
                progress(.originals(completed: index + 1, total: originals.count))
            }

            var files = [
                try fingerprint(LibraryFiles.database(in: staging), relativeTo: staging),
                try fingerprint(staging.appending(path: "manifest.json"), relativeTo: staging),
            ]
            for original in try LibraryFiles.originalFiles(in: targetOriginals) {
                try Task.checkCancellation()
                files.append(try fingerprint(original, relativeTo: staging))
            }
            if let exportingVersion {
                let library = try LibraryFiles.read(
                    LibraryManifest.self, from: staging.appending(path: "manifest.json"))
                let manifest = BackupManifest(
                    formatVersion: BackupManifest.currentVersion, exportedAt: createdAt,
                    libraryID: library.libraryID, applicationVersion: exportingVersion,
                    migrations: migrations, counts: counts, files: files)
                try LibraryFiles.write(manifest, to: staging.appending(path: "backup.json"))
                try checkpoint(.beforeValidation(staging))
                progress(.validating)
                try validateExport(in: staging, expected: manifest, assets: assets)
            } else {
                let manifest = SnapshotManifest(
                    formatVersion: 1, createdAt: createdAt, files: files)
                try LibraryFiles.write(manifest, to: staging.appending(path: "snapshot.json"))
            }
            try checkpoint(.beforePublish)
            try Task.checkCancellation()
            progress(.publishing)
            if exportingVersion != nil {
                try publishExport(staging, to: destination)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
            return LibrarySnapshot(directory: destination, createdAt: createdAt, files: files)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private func validateExport(
        in staging: URL, expected: BackupManifest, assets: [FileAsset]
    ) throws {
        let manifest = try LibraryFiles.read(
            BackupManifest.self, from: staging.appending(path: "backup.json"))
        guard manifest == expected else {
            throw LibraryError.invalidLibrary("The staged backup manifest failed validation.")
        }
        let library = try LibraryFiles.read(
            LibraryManifest.self, from: staging.appending(path: "manifest.json"))
        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(
            path: LibraryFiles.database(in: staging).path, configuration: configuration)
        defer { try? reader.close() }
        try reader.read { db in
            try db.checkForeignKeys()
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                try BackupQueries.counts(db) == manifest.counts,
                try FileAssetQueries.fetchAll(db) == assets,
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                    == manifest.migrations,
                library.libraryID == manifest.libraryID,
                try String.fetchOne(db, sql: "SELECT id FROM libraryMetadata")
                    == library.libraryID.uuidString,
                try Double.fetchOne(db, sql: "SELECT createdAt FROM libraryMetadata")
                    == library.createdAt.timeIntervalSince1970
            else {
                throw LibraryError.invalidLibrary("The staged backup database failed validation.")
            }
        }
        try reader.close()
        for file in manifest.files {
            try Task.checkCancellation()
            guard try fingerprint(staging.appending(path: file.path), relativeTo: staging) == file
            else {
                throw LibraryError.invalidLibrary("A staged backup file failed hash validation.")
            }
        }
        let originals = try LibraryFiles.originalFiles(in: LibraryFiles.originals(in: staging))
        guard Set(originals.map(\.lastPathComponent)) == Set(assets.map(\.storageKey)) else {
            throw LibraryError.invalidLibrary("The staged backup has an incomplete original store.")
        }
        for asset in assets {
            guard
                manifest.files.contains(
                    SnapshotFile(
                        path: "originals/\(asset.storageKey)", byteCount: asset.byteCount,
                        sha256: asset.sha256))
            else {
                throw LibraryError.invalidLibrary(
                    "The staged backup is missing a required original.")
            }
        }
    }

    private func publishExport(_ staging: URL, to destination: URL) throws {
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists { try LibraryFiles.requireDirectory(destination) }
        let result = staging.path.withCString { source in
            destination.path.withCString { target in
                renamex_np(source, target, exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // A successful swap leaves the previous destination at the staging path.
        if exists { try? FileManager.default.removeItem(at: staging) }
    }

    private func fingerprint(_ url: URL, relativeTo root: URL) throws -> SnapshotFile {
        try LibraryFiles.requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }
        return SnapshotFile(
            path: try LibraryFiles.relativePath(url, in: root),
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
