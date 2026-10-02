import CryptoKit
import Foundation
import GRDB

nonisolated struct LibrarySnapshotService {
    func create(
        from database: DatabaseQueue,
        generation: URL,
        destination: URL,
        createdAt: Date
    ) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(
                path: ".incomplete-\(destination.lastPathComponent)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let sourceOriginals = LibraryFiles.originals(in: generation)
            let originals = try LibraryFiles.originalFiles(in: sourceOriginals)
            let targetOriginals = LibraryFiles.originals(in: staging)
            try manager.createDirectory(at: targetOriginals, withIntermediateDirectories: false)

            let destinationDatabase = try DatabaseQueue(
                path: LibraryFiles.database(in: staging).path)
            try database.backup(to: destinationDatabase)
            try destinationDatabase.read { db in
                try db.checkForeignKeys()
                guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                    throw LibraryError.invalidLibrary("The recovery database failed validation.")
                }
            }
            try destinationDatabase.close()

            let sourceManifest = generation.appending(path: "manifest.json")
            try LibraryFiles.requireRegularFile(sourceManifest)
            try manager.copyItem(at: sourceManifest, to: staging.appending(path: "manifest.json"))
            for original in originals {
                try Task.checkCancellation()
                let relativePath = String(original.path.dropFirst(sourceOriginals.path.count + 1))
                let target = targetOriginals.appending(path: relativePath)
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: original, to: target)
            }

            var files = [
                try fingerprint(LibraryFiles.database(in: staging), relativeTo: staging),
                try fingerprint(staging.appending(path: "manifest.json"), relativeTo: staging),
            ]
            for original in try LibraryFiles.originalFiles(in: targetOriginals) {
                try Task.checkCancellation()
                files.append(try fingerprint(original, relativeTo: staging))
            }
            let manifest = SnapshotManifest(formatVersion: 1, createdAt: createdAt, files: files)
            try LibraryFiles.write(manifest, to: staging.appending(path: "snapshot.json"))
            try Task.checkCancellation()
            try manager.moveItem(at: staging, to: destination)
            return LibrarySnapshot(directory: destination, createdAt: createdAt, files: files)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private func fingerprint(_ url: URL, relativeTo root: URL) throws -> SnapshotFile {
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
            path: String(url.path.dropFirst(root.path.count + 1)),
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
