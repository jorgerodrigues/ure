import Foundation
import GRDB
import Testing

@testable import Ure

struct SearchStateTests {
    @Test(.timeLimit(.minutes(1)))
    func committedEditsRefreshSearchAndLocalListsWhileFailuresKeepSavedKeys() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        let search = SearchState(coordinator: coordinator)
        search.text = "0012–Å/stock"
        await search.observe()
        #expect(search.loadError != nil && !search.isLoading)
        search.retry()
        #expect(search.request.revision == 1)
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = SearchEditingFixture.make(coordinator)
        let overview = PartsOverviewState(coordinator: coordinator)
        var observations = SearchEditingFixture.observe(editing)
        observations += [Task { await search.observe() }, Task { await overview.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil {
            !search.isLoading && search.loadError == nil && !editing.parts.isLoading
                && !overview.isLoading
        }
        #expect(search.results.isEmpty)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        draft.links[0].supplierStockCode = "0012–Å/stock"
        let service = PartService(coordinator: coordinator)
        let part = try await service.save(draft, for: job.id, editing: nil)
        try await SearchEditingFixture.waitUntil {
            search.results.first?.recordID == part.id && editing.parts.parts.count == 1
                && overview.rows.count == 1
        }
        overview.searchText = "0012–å/stock"
        #expect(overview.filteredRows.map(\.id) == [part.id])
        #expect(editing.parts.records(for: job.id, matching: "0012–å/stock").map(\.id) == [part.id])
        var edit = PartDraft(part: part)
        edit.links[0].supplierStockCode = "replacement"
        edit.status = .arrived
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await service.save(edit, for: job.id, editing: part.id)
        }
        #expect(search.results.first?.recordID == part.id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("replacement", in: $0) }.isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        let saved = try await service.save(edit, for: job.id, editing: part.id)
        try await SearchEditingFixture.waitUntil {
            search.results.isEmpty && overview.filteredRows.isEmpty
        }
        #expect(
            try await coordinator.read { try SearchQueries.fetch("replacement", in: $0) }.map(
                \.recordID) == [part.id])
        edit = PartDraft(part: saved)
        edit.links = []
        _ = try await service.save(edit, for: job.id, editing: part.id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("replacement", in: $0) }.isEmpty)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        search.text = "   "
        await search.observe()
        #expect(search.results.isEmpty && !search.hasQuery && search.loadError == nil)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func everyResultSelectsExactSavedOwnersAndLeavesReferencesBehindTheirOpenButtons() async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let jobOwner = owners[1]
        guard case .job(let jobID) = jobOwner else { throw SearchFixtureFailure() }
        let job = try #require(try await coordinator.read { try JobQueries.fetch(jobID, in: $0) })
        let editing = SearchEditingFixture.make(coordinator)
        let navigation = WorkshopNavigation(configuration: AppConfiguration.current)
        let search = SearchState(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let pdf = try DocumentFixture.source(in: fixture)
        var records: [(String, SearchKind, UUID, NoteOwner)] = []
        for (index, owner) in owners.enumerated() {
            var noteDraft = NoteDraft(occurredAt: date)
            noteDraft.title = "Duplicate needle"
            noteDraft.body = "body \(index)"
            let note = try await NoteService(coordinator: coordinator).save(
                noteDraft, for: owner, editing: nil)
            records.append(("body \(index)", .note, note.id, owner))
            let itemOwner: LibraryItemOwner
            switch owner {
            case .watch(let id): itemOwner = .watch(id);
            case .job(let id): itemOwner = .job(id);
            case .caliber(let id): itemOwner = .caliber(id)
            }
            var referenceDraft = ReferenceFixture.draft
            referenceDraft.title = "Link needle \(index)"
            let item = try await ReferenceService(coordinator: coordinator).save(
                referenceDraft, for: itemOwner, editing: nil)
            records.append((referenceDraft.title, .link, item.id, owner))
            let photo = try #require(
                await PhotoService(coordinator: coordinator).importFiles([source], for: itemOwner)
                    .first
            ).outcome.get()
            var photoDraft = PhotoDraft(item: photo.item)
            photoDraft.title = "Photo needle \(index)"
            _ = try await PhotoService(coordinator: coordinator).save(
                photoDraft, for: itemOwner, editing: photo.id)
            records.append((photoDraft.title, .photo, photo.id, owner))
            let document = try #require(
                await DocumentService(coordinator: coordinator).importFiles([pdf], for: itemOwner)
                    .first
            ).outcome.get()
            var documentDraft = DocumentDraft(item: document.item)
            documentDraft.title = "PDF needle \(index)"
            _ = try await DocumentService(coordinator: coordinator).save(
                documentDraft, for: itemOwner, editing: document.id)
            records.append((documentDraft.title, .document, document.id, owner))
        }
        var partDraft = PartFixture.draft()
        partDraft.description = "Part needle"
        let part = try await PartService(coordinator: coordinator).save(
            partDraft, for: jobID, editing: nil)
        records.append((partDraft.description, .part, part.id, .job(jobID)))
        let observations = SearchEditingFixture.observe(editing)
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil { SearchEditingFixture.loaded(editing) }
        for (text, kind, id, owner) in records {
            search.text = text
            let observation = Task { await search.observe() }
            try await SearchEditingFixture.waitUntil {
                search.results.contains { $0.recordID == id }
            }
            search.isPresented = true
            search.open(
                "\(kind.rawValue)-\(id.uuidString)", editing: editing, navigation: navigation)
            #expect(!search.isPresented && search.navigationError == nil)
            switch owner {
            case .watch(let watchID):
                #expect(
                    editing.watches.selectedID == watchID && editing.jobs.selectedID == nil
                        && navigation.selection == .watches)
            case .job(let id):
                #expect(
                    editing.jobs.selectedID == id && editing.watches.selectedID == job.watchID
                        && navigation.selection == .watches)
            case .caliber(let id):
                #expect(
                    editing.calibers.selectedID == id && editing.jobs.selectedID == nil
                        && navigation.selection == .calibers)
            }
            #expect(editing.notes.selectedID == (kind == .note ? id : nil))
            #expect(editing.references.selectedID == (kind == .link ? id : nil))
            #expect(editing.photos.selectedID == (kind == .photo ? id : nil))
            #expect(editing.documents.selectedID == (kind == .document ? id : nil))
            #expect(editing.parts.selectedID == (kind == .part ? id : nil))
            #expect(editing.tasks.selectedID == nil)
            observation.cancel(); await observation.value
        }
        for (kind, id, text) in [
            (SearchKind.job, job.id, job.title), (.watch, job.watchID, "Bench watch"),
            (.caliber, try #require(editing.calibers.calibers.first?.id), "0012–Å"),
        ] {
            search.text = text
            let observation = Task { await search.observe() }
            try await SearchEditingFixture.waitUntil {
                !search.isLoading && search.results.contains { $0.recordID == id }
            }
            let before = search.navigationRevision
            search.open(
                "\(kind.rawValue)-\(id.uuidString)", editing: editing, navigation: navigation)
            #expect(search.navigationRevision == before + 1 && editing.parts.selectedID == nil)
            observation.cancel(); await observation.value
        }
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Retained"
        closure.unfinishedPartsReason = "Retained for history"
        _ = try await JobService(coordinator: coordinator).transition(jobID, using: closure)
        try await SearchEditingFixture.waitUntil {
            editing.jobs.jobs.first { $0.id == jobID }?.stage == .completed
        }
        search.text = partDraft.description
        let observation = Task { await search.observe() }
        defer { observation.cancel() }
        try await SearchEditingFixture.waitUntil { search.results.first?.recordID == part.id }
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        #expect(
            editing.parts.selectedID == part.id
                && !editing.parts.canWrite(jobID, jobs: editing.jobs))
        observation.cancel(); await observation.value
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func navigationProtectsDraftsAndRemovedResultsLeaveCurrentSelectionUntouched() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let first = try await JobTaskFixture.job(coordinator)
        let second = try await JobTaskFixture.job(coordinator)
        var draft = PartFixture.draft()
        draft.description = "Needle part"
        let part = try await PartService(coordinator: coordinator).save(
            draft, for: second.id, editing: nil)
        let editing = SearchEditingFixture.make(coordinator)
        let navigation = WorkshopNavigation(configuration: AppConfiguration.current)
        let search = SearchState(coordinator: coordinator)
        search.text = draft.description
        let observations = SearchEditingFixture.observe(editing) + [Task { await search.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil {
            SearchEditingFixture.loaded(editing) && search.results.count == 1
        }
        editing.watches.select(first.watchID)
        editing.watches.edit()
        editing.watches.draft?.name = "Keep correction"
        search.present()
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        #expect(editing.showsUnsavedChanges && editing.watches.selectedID == first.watchID)
        editing.stay()
        #expect(editing.watches.draft?.name == "Keep correction" && search.isPresented)
        editing.watches.draft?.name = ""
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        await editing.saveAndContinue()
        #expect(
            editing.watches.saveError != nil && editing.watches.selectedID == first.watchID
                && search.isPresented)
        editing.watches.draft?.name = "Keep correction"
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        await editing.saveAndContinue()
        #expect(
            editing.watches.selectedID == second.watchID && editing.jobs.selectedID == second.id
                && editing.parts.selectedID == part.id)
        editing.parts.edit(jobs: editing.jobs)
        editing.parts.draft?.description = "Draft discarded"
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        editing.discardAndContinue()
        #expect(editing.parts.draft == nil && editing.parts.selectedID == part.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "DELETE FROM partRequirement WHERE id = ?", arguments: [part.id.uuidString])
        }
        try await SearchEditingFixture.waitUntil {
            search.results.isEmpty && editing.parts.parts.isEmpty
        }
        search.open("Part-\(part.id.uuidString)", editing: editing, navigation: navigation)
        #expect(editing.jobs.selectedID == second.id)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }
}

enum SearchEditingFixture {
    static func make(_ coordinator: LibraryCoordinator) -> WorkshopEditing {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(
                service: ReferenceService(coordinator: coordinator, openBrowser: { _ in false })),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(
                service: PartService(coordinator: coordinator, openBrowser: { _ in false })))
    }
    static func observe(_ editing: WorkshopEditing) -> [Task<Void, Never>] {
        [
            Task { await editing.watches.observe() }, Task { await editing.calibers.observe() },
            Task { await editing.jobs.observe() }, Task { await editing.notes.observe() },
            Task { await editing.references.observe() }, Task { await editing.photos.observe() },
            Task { await editing.documents.observe() }, Task { await editing.tasks.observe() },
            Task { await editing.parts.observe() },
        ]
    }
    static func loaded(_ editing: WorkshopEditing) -> Bool {
        !editing.watches.isLoading && !editing.calibers.isLoading && !editing.jobs.isLoading
            && !editing.notes.isLoading && !editing.references.isLoading
            && !editing.photos.isLoading
            && !editing.documents.isLoading && !editing.tasks.isLoading && !editing.parts.isLoading
    }
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SearchFixtureFailure()
    }
}
