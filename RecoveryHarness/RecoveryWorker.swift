import Darwin
import Foundation
import GRDB

@main
struct RecoveryWorker {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { throw HarnessError.invalidArguments }
            let worker = try RecoveryOperation(
                operation: arguments[1], directory: URL(filePath: arguments[2]),
                checkpoint: arguments[3])
            try await worker.run()
        } catch {
            let message = "Recovery worker failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }
}

nonisolated enum HarnessError: Error {
    case invalidArguments
    case notIsolated
    case missingRecord
    case unexpectedOutcome
}

nonisolated struct RecoveryOperation: Sendable {
    let operation: String
    let directory: URL
    let checkpoint: String
    var root: URL { directory.appending(path: "library") }
    var package: URL { directory.appending(path: "export.watchbackup") }

    init(operation: String, directory: URL, checkpoint: String) throws {
        self.operation = operation
        self.directory = directory
        self.checkpoint = checkpoint
        let environment = ProcessInfo.processInfo.environment
        guard environment["URE_TESTING"] == "1",
            environment["URE_TEST_LIBRARY_PATH"] == root.path,
            try Data(contentsOf: directory.appending(path: ".ure-recovery-case"))
                == Data("isolated W029 library".utf8)
        else { throw HarnessError.notIsolated }
        try LibraryFiles.requireDirectory(directory)
    }

    func interrupt(_ name: String) throws {
        guard checkpoint == name else { return }
        try Data(name.utf8).write(to: directory.appending(path: "reached.txt"), options: .atomic)
        Darwin.kill(Darwin.getpid(), SIGKILL)
        Darwin.exit(2)
    }

    var dependencies: LibraryDependencies {
        LibraryDependencies(
            importCheckpoint: { step in
                if checkpoint == "import.beforeCleanup", step == .beforeCommit {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try interrupt("import.\(step)")
            },
            backupCheckpoint: { step in
                switch step {
                case .beforeValidation: try interrupt("backup.beforeValidation")
                default: try interrupt("backup.\(step)")
                }
            },
            restoreCheckpoint: { step in try interrupt("stage.\(step)") },
            activationCheckpoint: { step in
                if checkpoint == "restore.beforeRollback", step == .beforeFirstOpen {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try interrupt("restore.\(step)")
            },
            upgradeCheckpoint: { step in try interrupt("upgrade.\(step)") })
    }

    func run() async throws {
        var migrator = LibrarySchema.migrator
        if checkpoint == "upgrade.transaction" {
            migrator.registerMigration("w029-interrupted-transaction") { db in
                try db.execute(sql: "DELETE FROM note")
                try interrupt("upgrade.transaction")
            }
        }
        let coordinator = LibraryCoordinator(
            root: root, dependencies: dependencies, migrator: migrator)
        _ = try await coordinator.open()
        switch operation {
        case "open": break
        case "import-photo", "import-pdf":
            let owner = try await watchOwner(coordinator)
            let sources = directory.appending(path: "sources")
            if operation == "import-photo" {
                let results = await PhotoService(coordinator: coordinator).importFiles(
                    [sources.appending(path: "photo.png")], for: owner)
                guard let result = results.first else { throw HarnessError.unexpectedOutcome }
                _ = try result.outcome.get()
            } else {
                let results = await DocumentService(coordinator: coordinator).importFiles(
                    [sources.appending(path: "technical.pdf")], for: owner)
                guard let result = results.first else { throw HarnessError.unexpectedOutcome }
                _ = try result.outcome.get()
            }
        case "export":
            _ = try await coordinator.exportBackup(to: package, applicationVersion: "W029")
        case "stage":
            _ = try await coordinator.stageRestore(from: package)
        case "restore":
            let staged = try await coordinator.stageRestore(from: package)
            let result = try await coordinator.activateRestore(staged)
            guard result.outcome == .restored else { throw HarnessError.unexpectedOutcome }
            try await result.coordinator.close()
        default: throw HarnessError.invalidArguments
        }
        try await coordinator.close()
    }

    private func watchOwner(_ coordinator: LibraryCoordinator) async throws -> LibraryItemOwner {
        guard let id = try await coordinator.read({ try WatchQueries.fetchAll($0).first?.id })
        else { throw HarnessError.missingRecord }
        return .watch(id)
    }

}
