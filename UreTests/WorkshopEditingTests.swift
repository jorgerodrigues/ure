import Foundation
import GRDB
import Testing

@testable import Ure

struct WorkshopEditingTests {
    @Test
    func menuCancelPreservesSavedRecordsAndCannotDismissPendingNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let session = WorkshopSession(
            coordinator: coordinator, configuration: AppConfiguration(libraryRoot: fixture.root))
        let editing = session.editing
        #expect(!editing.canCancelDraft)
        session.watches.create()
        #expect(!editing.hasUnsavedChanges)
        #expect(editing.canCancelDraft)
        editing.cancelDraft()
        #expect(session.watches.draft == nil)
        session.watches.create()
        session.watches.draft?.name = "Saved watch"
        #expect(await session.watches.save())
        let saved = try #require(session.watches.selectedWatch)
        session.watches.edit()
        session.watches.draft?.name = "Keep this draft"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(!editing.canCancelDraft)
        editing.cancelDraft()
        #expect(!navigated)
        #expect(editing.isNavigationPending)
        #expect(session.watches.draft?.name == "Keep this draft")
        editing.stay()
        #expect(editing.canCancelDraft)
        editing.cancelDraft()
        #expect(session.watches.draft == nil)
        #expect(session.watches.selectedWatch == saved)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [saved])
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
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: MaterialState(service: MaterialService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
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
        #expect(calibers.selectedCaliber == nil)
        try await coordinator.close()
    }
}
