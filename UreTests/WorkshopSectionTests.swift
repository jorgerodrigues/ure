import Foundation
import Testing

@testable import Ure

struct WorkshopSectionTests {
    @Test
    func theSidebarGroupsTheSectionsAndCommandOneToFourSelectThemInOrder() {
        #expect(WorkshopSectionGroup.allCases.map(\.title) == ["Workshop", "Library"])
        #expect(WorkshopSectionGroup.workshop.sections == [.jobs, .parts])
        #expect(WorkshopSectionGroup.library.sections == [.watches, .calibers])
        #expect(
            WorkshopSection.allCases.map(\.title) == ["Jobs", "Parts", "Watches", "Calibers"])
        #expect(WorkshopSection.allCases.map(\.shortcut) == ["1", "2", "3", "4"])
        let navigation = WorkshopNavigation(configuration: AppConfiguration.current)
        #expect(navigation.selectedSection == .jobs)
        let request = navigation.searchFocusRequest
        navigation.focusSearch()
        #expect(navigation.searchFocusRequest == request + 1)
    }

    @Test
    func theNewCommandAndTheToolbarButtonShareTheirName() {
        #expect(NewRecord.title(in: .jobs) == "New Job")
        #expect(NewRecord.title(in: .watches) == "New Watch")
        #expect(NewRecord.title(in: .calibers) == "New Caliber")
        #expect(NewRecord.title(in: .parts) == "New Watch")
        #expect(RecordBack.watchTitle == "Back to Watch")
        #expect(RecordBack.jobTitle == "Back to Job")
        #expect(ToolbarSearchLayout.prompt == "Search")
    }

    @Test(.timeLimit(.minutes(1)))
    func newJobStartsWithoutAWatchAndNewWatchAndNewCaliberOpenTheirSection() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let editing = JobListFixture.editing(coordinator)
        let navigation = WorkshopNavigation(configuration: AppConfiguration.current)
        let search = SearchState(coordinator: coordinator)
        for section in WorkshopSection.allCases {
            #expect(!NewRecord.canMake(in: section, editing: editing))
        }
        let observations = [
            Task { await editing.watches.observe() }, Task { await editing.calibers.observe() },
            Task { await editing.jobs.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil {
            !editing.watches.isLoading && !editing.calibers.isLoading && !editing.jobs.isLoading
        }
        let watch = try await WatchService(coordinator: coordinator).make("Ventura")
        editing.watches.select(watch.id)
        search.present()

        NewRecord.make(in: .jobs, editing: editing, navigation: navigation, search: search)
        try await JobListFixture.waitUntil { editing.jobs.selectedJob != nil }
        let job = try #require(editing.jobs.selectedJob)
        #expect(job.title == "New Job" && job.watchID == nil && job.stage == .inProgress)
        #expect(editing.jobs.titleToFocus == job.id && editing.watches.selectedID == nil)
        #expect(navigation.selectedSection == .jobs && !search.isPresented)

        navigation.selection = .calibers
        NewRecord.make(in: .calibers, editing: editing, navigation: navigation, search: search)
        try await JobListFixture.waitUntil { editing.calibers.selectedCaliber != nil }
        #expect(editing.calibers.selectedCaliber?.designation == "New Caliber")
        #expect(navigation.selectedSection == .calibers)

        navigation.selection = .parts
        NewRecord.make(in: .parts, editing: editing, navigation: navigation, search: search)
        try await JobListFixture.waitUntil { editing.watches.selectedWatch?.name == "New Watch" }
        #expect(navigation.selectedSection == .watches && editing.jobs.selectedID == nil)
        for observation in observations {
            observation.cancel()
            await observation.value
        }
        try await coordinator.close()
    }
}
