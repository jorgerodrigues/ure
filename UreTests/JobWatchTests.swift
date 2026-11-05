import Foundation
import GRDB
import Testing

@testable import Ure

// A job can start without a watch while you set it up, and the watch picker gives it one.
struct JobWatchTests {
    @Test(.timeLimit(.minutes(1)))
    func aJobWithoutAWatchKeepsWhatYouTypedAfterYouQuit() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let state = JobState(service: JobService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { !state.isLoading }

        // New Job makes "New Job" without a watch and puts the cursor in its title.
        #expect(await state.create())
        let id = try #require(state.selectedID)
        #expect(state.titleToFocus == id && state.selectedJob?.title == "New Job")
        #expect(state.selectedJob?.watchID == nil && state.watchID == nil)
        let service = JobService(coordinator: coordinator)
        _ = try await service.update(id, .title("New crystal"))
        _ = try await service.update(id, .problem("The crystal is cracked."))
        try await RecordNotesService(coordinator: coordinator).save(
            "Ask for the box.", for: .job(id))
        let step = try #require(
            try await ChecklistService(coordinator: coordinator).save(
                [ChecklistStep(id: UUID(), text: "Fit the new crystal")], for: id
            ).first)
        let part = try await PartService(coordinator: coordinator).add(
            named: "Sapphire 30.0 mm", to: id)
        let link = try await MaterialFixture.link(
            titled: "Crystal sizes", for: .job(id), in: coordinator)
        _ = try await service.setStage(id, to: .waiting)
        _ = try await service.update(id, .waitingFor("the owner’s answer"))
        observation.cancel()
        await observation.value
        try await coordinator.close()

        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        let job = try #require(try await reopened.read { try JobQueries.fetch(id, in: $0) })
        #expect(job.watchID == nil && job.title == "New crystal")
        #expect(job.problem == "The crystal is cracked." && job.stage == .waiting)
        #expect(job.waitingFor == "the owner’s answer")
        #expect(
            try await RecordNotesService(coordinator: reopened).text(for: .job(id))
                == "Ask for the box.")
        #expect(
            try await reopened.read { try ChecklistQueries.ordered(for: id, in: $0) }.map(\.id)
                == [step.id])
        #expect(
            try await reopened.read(PartListQueries.fetch).map(\.id) == [part.id])
        #expect(
            try await reopened.read(LibraryItemQueries.fetchAll).map(\.id).contains(link.id))
        let rows = try await reopened.read { try JobListQueries.fetch($0, doneSince: .distantPast) }
        #expect(rows.map(\.id) == [id] && rows.first?.watch == nil)
        let found = try await reopened.read { try SearchQueries.fetch("new crystal", in: $0) }
        #expect(found.map(\.recordID) == [id])
        #expect(found.first?.context == "No watch yet · New crystal")
        try await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pickingAWatchGivesTheJobItsWatchAndUndoPutsBackNoWatch() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).make(
            "Railroad pocket watch", brand: "Hamilton")
        let editing = JobListFixture.editing(coordinator)
        let state = editing.jobs
        let watches = editing.watches
        let observations = [Task { await state.observe() }, Task { await watches.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil { !state.isLoading && !watches.isLoading }
        #expect(await state.create())
        let id = try #require(state.selectedID)
        let undo = UndoManager()
        undo.groupsByEvent = false

        let picker = WatchPickerModel()
        picker.type("rail")
        let items = picker.items(watches: watches.watches, calibers: [], jobs: state.jobs)
        let item = try #require(picker.highlightedItem(in: items))
        undo.beginUndoGrouping()
        #expect(await picker.pick(item, editing: editing, undoManager: undo))
        undo.endUndoGrouping()
        #expect(picker.query.isEmpty)
        #expect(try await stored(id, coordinator)?.watchID == watch.id)
        #expect(state.watchID == watch.id && watches.selectedID == watch.id)
        #expect(undo.undoMenuItemTitle == "Undo Choose Watch")

        undo.undo()
        await state.waitForWatchChanges()
        #expect(try await stored(id, coordinator)?.watchID == nil)
        #expect(state.watchID == nil && state.selectedJob?.watchID == nil)
        #expect(undo.redoMenuItemTitle == "Redo Choose Watch")
        undo.redo()
        await state.waitForWatchChanges()
        #expect(try await stored(id, coordinator)?.watchID == watch.id)
        state.discardUndo()
        for observation in observations {
            observation.cancel()
            await observation.value
        }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aWatchWithAnOpenJobNeverGetsASecondOpenJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = JobService(coordinator: coordinator)
        let ventura = try await WatchService(coordinator: coordinator).make(
            "Ventura", brand: "Hamilton")
        let open = try await service.start(for: ventura.id, title: "Full service")

        // The service and the database each refuse a second open job.
        let typed = try await service.start(for: nil, title: "New crystal")
        await #expect(throws: JobError.openJobExists(open)) {
            try await service.setWatch(typed.id, to: ventura.id)
        }
        await #expect(throws: JobError.openJobExists(open)) {
            try await service.start(for: ventura.id)
        }
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE job SET watchID = ? WHERE id = ?",
                    arguments: [ventura.id.uuidString, typed.id.uuidString])
            }
        }
        #expect(try await stored(typed.id, coordinator)?.watchID == nil)

        // A Done job can take a watch that has an open job, and many jobs can wait for one.
        let finished = try await service.start(for: nil, title: "Old crystal")
        _ = try await service.setStage(finished.id, to: .done)
        #expect(try await service.setWatch(finished.id, to: ventura.id).watchID == ventura.id)
        await #expect(throws: JobError.openJobExists(open)) {
            try await service.setStage(finished.id, to: .inProgress)
        }
        _ = try await service.start(for: nil)

        // The picker shows the watch's open job, and picking it opens that job. The job being
        // set up goes when nothing is in it yet, and stays when you typed in it.
        let editing = JobListFixture.editing(coordinator)
        let state = editing.jobs
        let watches = editing.watches
        let observations = [Task { await state.observe() }, Task { await watches.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil { !state.isLoading && !watches.isLoading }
        let picker = WatchPickerModel()
        picker.type("vent")
        let items = picker.items(watches: watches.watches, calibers: [], jobs: state.jobs)
        guard case .watch(let choice) = items.first else {
            Issue.record("The picker shows no watch")
            return
        }
        #expect(choice.openJob?.id == open.id)
        #expect(choice.detail == "Hamilton · already has an open job")

        #expect(await state.create())
        let blank = try #require(state.selectedID)
        #expect(await picker.pick(.watch(choice), editing: editing, undoManager: nil))
        #expect(state.selectedID == open.id && watches.selectedID == ventura.id)
        #expect(try await stored(blank, coordinator) == nil)
        #expect(try await stored(open.id, coordinator)?.watchID == ventura.id)

        // Typing that has not saved yet keeps the job: the pick waits for the save first.
        #expect(await state.create())
        let pending = try #require(state.selectedID)
        let title = try #require(state.facts(for: pending)?.title)
        title.beginEditing()
        title.change(to: "Strap and buckle", undoManager: nil)
        #expect(await picker.pick(.watch(choice), editing: editing, undoManager: nil))
        #expect(state.selectedID == open.id)
        #expect(try await stored(pending, coordinator)?.title == "Strap and buckle")
        title.endEditing()

        let stays = try #require(state.jobs.first { $0.id == typed.id })
        state.open(stays)
        #expect(await picker.pick(.watch(choice), editing: editing, undoManager: nil))
        #expect(state.selectedID == open.id)
        #expect(try await stored(typed.id, coordinator)?.title == "New crystal")
        state.open(stays)
        #expect(await !state.chooseWatch(ventura.id))
        #expect(state.saveError == JobError.openJobExists(open).localizedDescription)
        #expect(try await stored(typed.id, coordinator)?.watchID == nil)
        for observation in observations {
            observation.cancel()
            await observation.value
        }
        try await coordinator.close()
    }

    @Test
    func anArchivedWatchCantTakeAJobAndTakingAWatchAwayClearsItsCoverFromTheJob() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let service = JobService(coordinator: coordinator)
        let watches = WatchService(coordinator: coordinator)
        let archived = try await watches.make("Smiths", brand: "Smiths")
        _ = try await ArchiveService(coordinator: coordinator).setWatch(archived.id, archived: true)
        let job = try await service.start(for: nil)
        await #expect(throws: ArchiveError.archived) {
            try await service.setWatch(job.id, to: archived.id)
        }
        await #expect(throws: JobError.unavailableWatch) {
            try await service.setWatch(job.id, to: UUID())
        }

        let watch = try await watches.make("Field watch", brand: "Smiths")
        _ = try await service.setWatch(job.id, to: watch.id)
        let photo = try await MaterialFixture.file(
            try fixture.source(type: .png), for: .job(job.id), in: coordinator)
        try await MaterialService(coordinator: coordinator).setCover(photo.id, for: watch.id)
        let unwatched = try await service.setWatch(job.id, to: nil)
        #expect(unwatched.watchID == nil)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?
                .coverPhotoID == nil)
        let check = try await coordinator.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        #expect(check == 0)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewWatchFromThePickerIsMadeWithTheTypedNameAndStaysAfterUndo() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let editing = JobListFixture.editing(coordinator)
        let state = editing.jobs
        let watches = editing.watches
        let observations = [Task { await state.observe() }, Task { await watches.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil { !state.isLoading && !watches.isLoading }
        #expect(await state.create())
        let id = try #require(state.selectedID)
        let picker = WatchPickerModel()
        picker.type("  ham ")
        let items = picker.items(watches: watches.watches, calibers: [], jobs: state.jobs)
        #expect(items == [.newWatch("ham")])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(
            await picker.pick(.newWatch("ham"), editing: editing, undoManager: undo))
        undo.endUndoGrouping()
        let watchID = try #require(try await stored(id, coordinator)?.watchID)
        let made = try #require(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0) })
        #expect(made.name == "ham" && watches.selectedID == watchID)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("ham", in: $0) }.contains {
                $0.recordID == watchID
            })
        undo.undo()
        await state.waitForWatchChanges()
        #expect(try await stored(id, coordinator)?.watchID == nil)
        #expect(try await coordinator.read { try WatchQueries.fetch(watchID, in: $0) } != nil)
        state.discardUndo()
        for observation in observations {
            observation.cancel()
            await observation.value
        }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func openingAWatchsJobDiscardsOnlyTheBlankJobItNamesAndAFailedNewJobSaysWhy() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = JobService(coordinator: coordinator)
        let watch = try await WatchService(coordinator: coordinator).make("Ventura")
        let open = try await service.start(for: watch.id)
        let first = try await service.start(for: nil)
        let second = try await service.start(for: nil)
        let state = JobState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { state.jobs.count == 3 }
        state.open(try #require(state.jobs.first { $0.id == second.id }))
        #expect(await state.openOpenJob(of: watch.id, discardingBlank: nil)?.id == open.id)
        #expect(try await stored(second.id, coordinator) != nil)
        state.open(try #require(state.jobs.first { $0.id == second.id }))
        #expect(await state.openOpenJob(of: watch.id, discardingBlank: first.id)?.id == open.id)
        #expect(try await stored(first.id, coordinator) == nil)
        #expect(try await stored(second.id, coordinator) != nil)

        state.close()
        try await JobTaskFixture.failWrites(coordinator, on: "job")
        #expect(await !state.create())
        #expect(state.selectedID == nil && state.saveError != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "job")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test
    func onlyAJobWithNothingInItIsDiscarded() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = JobService(coordinator: coordinator)
        let blank = try await service.start(for: nil)
        #expect(try await service.discardIfBlank(blank.id))
        #expect(try await stored(blank.id, coordinator) == nil)
        let titled = try await service.start(for: nil, title: "New crystal")
        let problem = try await service.start(for: nil)
        _ = try await service.update(problem.id, .problem("Cracked"))
        let noted = try await service.start(for: nil)
        try await RecordNotesService(coordinator: coordinator).save("Box", for: .job(noted.id))
        let tasked = try await service.start(for: nil)
        _ = try await ChecklistService(coordinator: coordinator).save(
            [ChecklistStep(id: UUID(), text: "Clean")], for: tasked.id)
        let watched = try await JobTaskFixture.job(coordinator)
        _ = try await service.update(watched.id, .title(JobService.newTitle))
        for job in [titled, problem, noted, tasked, watched] {
            #expect(try await !service.discardIfBlank(job.id))
            #expect(try await stored(job.id, coordinator) != nil)
        }
        try await coordinator.close()
    }

    @Test
    func thePickerFindsWatchesByNameBrandOrCaliber() throws {
        let caliber = CaliberRecord(
            id: UUID(), designation: "992B", manufacturer: "Hamilton", createdAt: .now,
            updatedAt: .now)
        let omega = CaliberRecord(
            id: UUID(), designation: "552", manufacturer: "Omega", createdAt: .now,
            updatedAt: .now)
        let railroad = WatchRecord(
            id: UUID(), name: "Railroad pocket watch", brand: "Hamilton",
            approximateYear: "1940s", caliberID: caliber.id, createdAt: .now, updatedAt: .now)
        let ventura = WatchRecord(
            id: UUID(), name: "Ventura", brand: "Hamilton", approximateYear: "1958",
            createdAt: .now, updatedAt: .now)
        let seamaster = WatchRecord(
            id: UUID(), name: "Grandfather’s Seamaster", brand: "Omega", caliberID: omega.id,
            createdAt: .now, updatedAt: .now)
        var archived = WatchRecord(
            id: UUID(), name: "Hamilton field", brand: "Hamilton", createdAt: .now,
            updatedAt: .now)
        archived.archivedAt = .now
        let open = JobRecord(
            id: UUID(), watchID: ventura.id, title: "Full service", stage: .inProgress,
            createdAt: .now, updatedAt: .now)
        let watches = [ventura, seamaster, railroad, archived]
        let calibers = [caliber, omega]

        func names(_ query: String) -> [String] {
            WatchPickerMatches.items(
                for: query, watches: watches, calibers: calibers, jobs: [open]
            ).map { item in
                switch item {
                case .watch(let choice): choice.watch.name
                case .newWatch(let name): "new: \(name)"
                }
            }
        }
        #expect(names("ham") == ["Railroad pocket watch", "Ventura", "new: ham"])
        #expect(names("992") == ["Railroad pocket watch", "new: 992"])
        #expect(names("OMEGA 552") == ["Grandfather’s Seamaster", "new: OMEGA 552"])
        #expect(names("seam") == ["Grandfather’s Seamaster", "new: seam"])
        #expect(names("") == ["Grandfather’s Seamaster", "Railroad pocket watch", "Ventura"])
        #expect(names("field") == ["new: field"])
        let first = WatchPickerMatches.items(
            for: "ham", watches: watches, calibers: calibers, jobs: [open]
        ).first
        guard case .watch(let choice) = first else {
            Issue.record("The picker shows no watch")
            return
        }
        #expect(choice.detail == "Hamilton · 1940s · Hamilton 992B" && choice.openJob == nil)

        let many = (0..<10).map { index in
            WatchRecord(
                id: UUID(), name: "Watch \(index)", createdAt: .now, updatedAt: .now)
        }
        #expect(
            WatchPickerMatches.items(for: "", watches: many, calibers: [], jobs: []).count
                == WatchPickerMatches.limit)

        let picker = WatchPickerModel()
        picker.move(by: 1, count: 3)
        picker.move(by: 5, count: 3)
        #expect(picker.highlighted == 2)
        picker.move(by: -9, count: 3)
        #expect(picker.highlighted == 0)
        picker.move(by: 1, count: 3)
        picker.type("h")
        #expect(picker.highlighted == 0 && picker.query == "h")
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> JobRecord? {
        try await coordinator.read { try JobQueries.fetch(id, in: $0) }
    }
}
