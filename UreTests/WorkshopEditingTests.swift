import Foundation
import GRDB
import Testing

@testable import Ure

struct WorkshopEditingTests {
    @Test
    func caliberDraftProtectsSectionNavigationAndSupportsStaySaveAndDiscard() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watches = WatchState(service: WatchService(coordinator: coordinator))
        let calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        let editing = WorkshopEditing(
            watches: watches, calibers: calibers,
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)))
        calibers.create()
        calibers.draft?.designation = "Pending caliber"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.hasUnsavedChanges)
        #expect(editing.showsUnsavedChanges)
        #expect(editing.unsavedChangesTitle == "Save changes to this caliber?")
        #expect(!navigated)
        editing.showsUnsavedChanges = false
        editing.stay()
        #expect(calibers.draft?.designation == "Pending caliber")
        editing.requestNavigation { navigated = true }
        editing.showsUnsavedChanges = false
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(!editing.hasUnsavedChanges)
        #expect(calibers.selectedCaliber?.designation == "Pending caliber")
        calibers.edit()
        calibers.draft?.designation = "Discarded edit"
        navigated = false
        editing.requestNavigation { navigated = true }
        editing.showsUnsavedChanges = false
        editing.discardAndContinue()
        #expect(navigated)
        #expect(calibers.selectedCaliber?.designation == "Pending caliber")
        try await coordinator.close()
    }

    @Test
    func failedCaliberSaveCancelsClosureAndKeepsTheDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failCaliberInsert BEFORE INSERT ON caliber
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        let watches = WatchState(service: WatchService(coordinator: coordinator))
        let calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        let editing = WorkshopEditing(
            watches: watches, calibers: calibers,
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)))
        calibers.create()
        calibers.draft?.designation = "Keep this draft"
        var closed = false
        var cancelled = false
        editing.requestNavigation({ closed = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!closed)
        #expect(cancelled)
        #expect(calibers.draft?.designation == "Keep this draft")
        #expect(calibers.saveError != nil)
        #expect(!editing.isNavigationPending)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func watchDraftRemainsProtectedByTheSharedGuard() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watches = WatchState(service: WatchService(coordinator: coordinator))
        let calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        let editing = WorkshopEditing(
            watches: watches, calibers: calibers,
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)))
        watches.create()
        watches.draft?.name = "Watch draft"
        var navigated = false
        var cancelled = false
        editing.requestNavigation { navigated = true }
        editing.requestNavigation({}, onCancel: { cancelled = true })
        #expect(cancelled)
        #expect(editing.unsavedChangesTitle == "Save changes to this watch?")
        #expect(!navigated)
        editing.showsUnsavedChanges = false
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(watches.selectedWatch?.name == "Watch draft")
        #expect(calibers.draft == nil)
        try await coordinator.close()
    }
}
