import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import PDFKit
import Testing

@testable import Ure

nonisolated struct ReleaseJourneyTests {
    @Test(arguments: ["fresh", "v10-documents", "v15-part-procurement"])
    func repairRestartAndRestorePreserveRecordsAndOriginals(start: String) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        if start != "fresh" { try seedRetainedLibrary(start, at: fixture.root) }
        var coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let retained = try await records(coordinator)
        let retainedAssets = try await coordinator.read(FileAssetQueries.fetchAll)
        var watchDraft = WatchDraft()
        watchDraft.name = "Release bench – Å時計"
        let watch = try await WatchService(coordinator: coordinator).save(watchDraft, editing: nil)
        #expect(watch.brand == nil && watch.caliberID == nil && watch.condition == .unknown)
        var jobDraft = JobDraft()
        jobDraft.title = "Inspect movement"
        let jobs = JobService(coordinator: coordinator)
        let job = try await jobs.save(jobDraft, for: watch.id, editing: nil)
        var note = NoteDraft(occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        note.title = "Finding"
        note.body = "Unknown specifications. Keep 00042-A/7."
        _ = try await NoteService(coordinator: coordinator).save(
            note, for: .job(job.id), editing: nil)
        var partDraft = PartFixture.draft()
        partDraft.manufacturerReference = "0012-A"
        var link = PartLinkDraft()
        link.url = "https://example.org/0012"
        partDraft.links = [link]
        let parts = PartService(coordinator: coordinator)
        let initialPart = try await parts.save(partDraft, for: job.id, editing: nil)
        var edit = PartDraft(part: initialPart)
        var secondLink = PartLinkDraft()
        secondLink.url = "https://example.org/supplier"
        secondLink.supplierStockCode = "00042-S"
        edit.links.append(secondLink)
        let linkedPart = try await parts.save(edit, for: job.id, editing: initialPart.id)
        #expect(linkedPart.record.manufacturerReference == "0012-A")
        #expect(linkedPart.links.map(\.url) == [link.url, secondLink.url])
        var waitingJob = JobTransitionDraft(stage: .waiting)
        waitingJob.waitingReason = "Need spring"
        _ = try await jobs.transition(job.id, using: waitingJob)
        let tasks = JobTaskService(coordinator: coordinator)
        #expect(try await progress(job.id, coordinator).fraction == nil)
        var taskDraft = JobTaskFixture.draft(.waiting)
        taskDraft.waitingReason = ""
        taskDraft.partIDs = [linkedPart.id]
        let waitingTask = try await tasks.save(taskDraft, for: job.id, editing: nil)
        var arrival = PartDraft(part: linkedPart)
        arrival.status = .arrived
        let arrived = try await parts.save(arrival, for: job.id, editing: linkedPart.id)
        #expect(TaskPartAvailability.label(for: [arrived.record]) == .partsAvailable)
        #expect(
            try await coordinator.read { try JobTaskQueries.fetch(waitingTask.id, in: $0) }
                == waitingTask)
        let done = try await tasks.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        _ = try await tasks.save(JobTaskFixture.draft(.skipped), for: job.id, editing: nil)
        #expect(try await progress(job.id, coordinator).percentage == 50)
        var reopen = JobTaskDraft(task: done)
        reopen.status = .toDo
        _ = try await tasks.save(reopen, for: job.id, editing: done.id)
        #expect(try await progress(job.id, coordinator).percentage == 0)
        let photoSource = try fixture.source(type: .jpeg, name: "bench.jpg")
        let pdfSource = try DocumentFixture.source(in: fixture)
        let photo = try await PhotoService(coordinator: coordinator).importFiles(
            [photoSource], for: .job(job.id))[0].outcome.get()
        let pdf = try await DocumentService(coordinator: coordinator).importFiles(
            [pdfSource], for: .job(job.id))[0].outcome.get()
        try FileManager.default.removeItem(at: fixture.sources)
        var completion = JobTransitionDraft(stage: .completed)
        completion.outcome = "Inspected; unresolved work documented"
        completion.unfinishedTasksReason = "Assembly remains for the next repair"
        let completed = try await jobs.transition(job.id, using: completion)
        jobDraft.title = "Follow-up repair"
        let followup = try await jobs.save(jobDraft, for: watch.id, editing: nil)
        #expect(followup.id != completed.id && followup.intakeSnapshot == job.intakeSnapshot)
        try await coordinator.close()
        coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        #expect(
            try await coordinator.read { try JobQueries.fetch(completed.id, in: $0) } == completed)
        let image = try await PhotoService(coordinator: coordinator).image(
            for: photo.asset.id, thumbnail: false)
        #expect(image.width == 12 && image.height == 16)
        let document = try await DocumentService(coordinator: coordinator).document(
            for: pdf.asset.id)
        #expect(document.pageCount == 3)
        let expected = try await records(coordinator)
        for (table, rows) in retained {
            #expect(Set(rows).isSubset(of: Set(expected[table] ?? [])))
        }
        let assets = try await coordinator.read(FileAssetQueries.fetchAll)
        #expect(Set(retainedAssets.map(\.id)).isSubset(of: Set(assets.map(\.id))))
        let backup = fixture.directory.appending(path: "release.watchbackup")
        _ = try await coordinator.exportBackup(to: backup, applicationVersion: "acceptance")
        let manifest = try LibraryFiles.read(
            BackupManifest.self, from: backup.appending(path: "backup.json"))
        for asset in assets {
            let bytes = try Data(
                contentsOf: backup.appending(path: "originals/\(asset.storageKey)"))
            #expect(Int64(bytes.count) == asset.byteCount && digest(bytes) == asset.sha256)
        }
        try await coordinator.close()
        let target = LibraryCoordinator(root: fixture.directory.appending(path: "restore-target"))
        _ = try await target.open()
        let staged = try await target.stageRestore(from: backup)
        let result = try await target.activateRestore(staged)
        #expect(result.outcome == .restored && result.recovery != nil)
        #expect(try await records(result.coordinator) == expected)
        for asset in assets {
            let bytes = try Data(
                contentsOf: try await result.coordinator.originalURL(for: asset.id))
            #expect(Int64(bytes.count) == asset.byteCount && digest(bytes) == asset.sha256)
        }
        #expect(
            try LibraryFiles.read(BackupManifest.self, from: backup.appending(path: "backup.json"))
                == manifest)
        try await result.coordinator.close()
    }

    private func progress(_ jobID: UUID, _ coordinator: LibraryCoordinator) async throws
        -> JobTaskProgress
    {
        try await coordinator.read { db in
            JobTaskProgress(tasks: try JobTaskQueries.ordered(for: jobID, in: db))
        }
    }

    private func records(_ coordinator: LibraryCoordinator) async throws -> [String: [String]] {
        try await coordinator.read { db in
            var result: [String: [String]] = [:]
            for table in try BackupQueries.counts(db).keys {
                let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(quoted)\"")
                    .map(\.description).sorted()
            }
            return result
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func seedRetainedLibrary(_ version: String, at root: URL) throws {
        let resources = try #require(Bundle(for: ReleaseJourneyResources.self).resourceURL)
            .appending(path: "Fixtures")
        let generationID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let generation = LibraryFiles.generation(generationID, in: root)
        let originals = LibraryFiles.originals(in: generation)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: resources.appending(path: "manifest.json"),
            to: generation.appending(path: "manifest.json"))
        try LibraryFiles.write(
            ActiveLibrary(formatVersion: 1, generationID: generationID),
            to: root.appending(path: "active-library.json"))
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let database = try DatabaseQueue(
            path: LibraryFiles.database(in: generation).path, configuration: configuration)
        let sql = try String(
            contentsOf: resources.appending(path: "\(version).sql"), encoding: .utf8)
        try database.writeWithoutTransaction { try $0.execute(sql: sql) }
        let assets = try database.read(FileAssetQueries.fetchAll)
        try database.close()
        for asset in assets {
            let name = asset.detectedType == .pdf ? "technical.pdf.base64" : "photo.base64"
            let encoded = try String(contentsOf: resources.appending(path: name), encoding: .utf8)
            let bytes = try #require(
                Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            #expect(Int64(bytes.count) == asset.byteCount && digest(bytes) == asset.sha256)
            try bytes.write(to: originals.appending(path: asset.storageKey))
        }
    }
}

private final class ReleaseJourneyResources: NSObject {}
