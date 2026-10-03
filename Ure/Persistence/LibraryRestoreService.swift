import Foundation
import GRDB

nonisolated struct LibraryRestoreService {
    let migrator: DatabaseMigrator
    let dependencies: LibraryDependencies

    func stage(from package: URL, in root: URL) throws -> StagedRestore {
        try Task.checkCancellation()
        let access = package.startAccessingSecurityScopedResource()
        defer { if access { package.stopAccessingSecurityScopedResource() } }
        return try RestoreFiles.withDirectory(package, item: "backup package") { source in
            let backup = try RestoreFiles.readManifest(
                BackupManifest.self, name: "backup.json", in: source)
            let byteCount = try validateManifest(backup)
            try validateContents(
                package, expected: ["backup.json", "manifest.json", "library.sqlite", "originals"],
                item: "backup package")
            try validateContents(
                LibraryFiles.originals(in: package),
                expected: Set(
                    backup.files.filter { $0.path.hasPrefix("originals/") }
                        .map { String($0.path.dropFirst("originals/".count)) }),
                item: "originals")
            return try stage(backup, byteCount: byteCount, source: source, in: root)
        }
    }

    private func stage(
        _ backup: BackupManifest, byteCount: Int64, source: Int32, in root: URL
    ) throws -> StagedRestore {
        let manager = FileManager.default
        let generations = root.appending(path: "generations", directoryHint: .isDirectory)
        try RestoreFiles.checking("staging") {
            try LibraryFiles.requireDirectory(root)
            try LibraryFiles.requireDirectory(generations)
        }
        let generationID = dependencies.makeID()
        let target = LibraryFiles.generation(generationID, in: root)
        let staging = generations.appending(
            path: ".restore-\(generationID.uuidString)", directoryHint: .isDirectory)
        guard !manager.fileExists(atPath: target.path) else {
            throw RestoreError.invalidItem("staging", "The generated library ID already exists.")
        }
        try RestoreFiles.checkSpace(
            byteCount, at: generations, item: "backup package",
            capacity: dependencies.restoreAvailableCapacity)
        try RestoreFiles.checking("staging") {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        }
        defer { try? manager.removeItem(at: staging) }
        let originals = LibraryFiles.originals(in: staging)
        try RestoreFiles.checking("originals") {
            try manager.createDirectory(at: originals, withIntermediateDirectories: false)
        }
        try RestoreFiles.withDirectory(staging, item: "staging") { destination in
            try RestoreFiles.withChildDirectory("originals", in: source) { sourceOriginals in
                try RestoreFiles.withChildDirectory("originals", in: destination) {
                    targetOriginals in
                    for file in backup.files {
                        try Task.checkCancellation()
                        if file.path.hasPrefix("originals/") {
                            try RestoreFiles.copy(
                                file, name: String(file.path.dropFirst("originals/".count)),
                                from: sourceOriginals, to: targetOriginals, staging: staging,
                                dependencies: dependencies)
                        } else {
                            try RestoreFiles.copy(
                                file, name: file.path, from: source, to: destination,
                                staging: staging, dependencies: dependencies)
                        }
                    }
                }
            }
        }
        try verify(backup.files, in: staging)
        let library = try RestoreFiles.withDirectory(staging, item: "staging") { directory in
            try RestoreFiles.readManifest(
                LibraryManifest.self, name: "manifest.json", in: directory)
        }
        guard library.formatVersion == LibraryManifest.currentVersion,
            library.libraryID == backup.libraryID, library.createdAt.timeIntervalSince1970.isFinite
        else {
            throw RestoreError.invalidItem(
                "manifest.json", "The library version or identity is invalid.")
        }
        let summary = try validateAndMigrate(
            backup, library: library, staging: staging, bytes: byteCount)
        try verify(backup.files.filter { $0.path.hasPrefix("originals/") }, in: staging)
        try RestoreFiles.checking("staging") {
            try dependencies.restoreCheckpoint(.beforePublish)
            try Task.checkCancellation()
            try manager.moveItem(at: staging, to: target)
        }
        return StagedRestore(
            library: LibraryInfo(generationID: generationID, manifest: library), summary: summary)
    }

    private func validateAndMigrate(
        _ backup: BackupManifest, library: LibraryManifest, staging: URL, bytes: Int64
    ) throws -> RestoreSummary {
        try RestoreFiles.checking("library.sqlite") {
            let reader = try RestoreDatabase.open(in: staging, readonly: true)
            defer { try? reader.close() }
            let counts = try RestoreDatabase.validate(
                reader, library: library, migrations: backup.migrations, migrator: migrator)
            guard counts == backup.counts else {
                throw RestoreError.invalidItem(
                    "library.sqlite", "The saved counts do not match backup.json.")
            }
            try validateAssets(try reader.read(RestoreDatabase.assets), files: backup.files)
        }
        let writer = try RestoreFiles.checking("library.sqlite") {
            try RestoreDatabase.open(in: staging, readonly: false)
        }
        defer { try? writer.close() }
        do {
            try Task.checkCancellation()
            if backup.migrations != migrator.migrations,
                let databaseFile = backup.files.first(where: { $0.path == "library.sqlite" })
            {
                try RestoreFiles.checkSpace(
                    databaseFile.byteCount, at: staging, item: "library.sqlite",
                    capacity: dependencies.restoreAvailableCapacity)
            }
            try dependencies.restoreCheckpoint(.beforeMigration)
            try migrator.migrate(writer)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError.migrationFailed
        }
        return try RestoreFiles.checking("library.sqlite") {
            let counts = try RestoreDatabase.validate(
                writer, library: library, migrations: migrator.migrations, migrator: migrator)
            let assets = try writer.read(RestoreDatabase.assets)
            try validateAssets(assets, files: backup.files)
            try writer.close()
            return RestoreSummary(
                exportedAt: backup.exportedAt, applicationVersion: backup.applicationVersion,
                counts: counts, originalCount: assets.count, byteCount: bytes,
                appliedMigrations: Array(migrator.migrations.dropFirst(backup.migrations.count)))
        }
    }

    private func verify(_ files: [SnapshotFile], in staging: URL) throws {
        try RestoreFiles.withDirectory(staging, item: "staging") { directory in
            try RestoreFiles.withChildDirectory("originals", in: directory) { originals in
                for file in files {
                    if file.path.hasPrefix("originals/") {
                        try RestoreFiles.verify(
                            file, name: String(file.path.dropFirst("originals/".count)),
                            in: originals)
                    } else {
                        try RestoreFiles.verify(file, name: file.path, in: directory)
                    }
                }
            }
        }
    }

    private func validateManifest(_ backup: BackupManifest) throws -> Int64 {
        guard backup.formatVersion == BackupManifest.currentVersion else {
            throw RestoreError.unsupportedVersion(backup.formatVersion)
        }
        guard backup.exportedAt.timeIntervalSince1970.isFinite,
            !backup.applicationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            backup.counts.values.allSatisfy({ $0 >= 0 })
        else {
            throw RestoreError.invalidItem(
                "backup.json", "The date, application version, or counts are invalid.")
        }
        guard !backup.migrations.isEmpty,
            backup.migrations == Array(migrator.migrations.prefix(backup.migrations.count))
        else { throw RestoreError.unsupportedSchema }
        var paths: Set<String> = []
        var total: Int64 = 0
        for file in backup.files {
            let originalKey = String(file.path.dropFirst("originals/".count))
            guard
                file.path == "library.sqlite" || file.path == "manifest.json"
                    || (file.path.hasPrefix("originals/")
                        && ManagedOriginals.assetID(for: originalKey) != nil),
                paths.insert(file.path).inserted, file.byteCount > 0,
                file.sha256.utf8.count == 64,
                file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else {
                throw RestoreError.invalidItem(
                    "backup.json", "A declared path, size, or hash is invalid.")
            }
            let sum = total.addingReportingOverflow(file.byteCount)
            guard !sum.overflow else {
                throw RestoreError.invalidItem(
                    "backup.json", "The total declared size is too large.")
            }
            total = sum.partialValue
            if file.path == "manifest.json", file.byteCount > RestoreFiles.maximumManifestBytes {
                throw RestoreError.invalidItem(
                    "manifest.json", "The manifest exceeds the supported size.")
            }
        }
        guard paths.contains("library.sqlite"), paths.contains("manifest.json") else {
            throw RestoreError.invalidItem(
                "backup.json", "The database or library manifest is not declared.")
        }
        return total
    }

    private func validateContents(_ directory: URL, expected: Set<String>, item: String) throws {
        try RestoreFiles.checking(item) {
            try LibraryFiles.requireDirectory(directory)
            let children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            var names: Set<String> = []
            for child in children {
                guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
                else {
                    throw RestoreError.invalidItem(item, "Symbolic links are not supported.")
                }
                if child.lastPathComponent == ".DS_Store" || child.lastPathComponent.hasPrefix("._")
                {
                    try LibraryFiles.requireRegularFile(child)
                } else {
                    names.insert(child.lastPathComponent)
                }
            }
            if let missing = expected.subtracting(names).sorted().first {
                var failedItem = missing
                if item == "originals" { failedItem = "originals/\(missing)" }
                throw RestoreError.invalidItem(failedItem, "A required item is missing.")
            }
            guard names == expected else {
                throw RestoreError.invalidItem(item, "The package has missing or unexpected items.")
            }
        }
    }

    private func validateAssets(_ assets: [FileAsset], files: [SnapshotFile]) throws {
        let originals = files.filter { $0.path.hasPrefix("originals/") }
        let expected = assets.map {
            SnapshotFile(
                path: "originals/\($0.storageKey)", byteCount: $0.byteCount, sha256: $0.sha256)
        }
        guard Set(originals.map(\.path)) == Set(expected.map(\.path)) else {
            throw RestoreError.invalidItem(
                "originals", "The store does not match the saved file assets.")
        }
        let declared = Dictionary(uniqueKeysWithValues: originals.map { ($0.path, $0) })
        for file in expected {
            guard declared[file.path] == file else {
                throw RestoreError.invalidItem(
                    file.path, "The saved asset size or hash does not match.")
            }
        }
    }
}
