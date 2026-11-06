import Foundation
import Observation

@Observable
final class WorkshopSession {
    let id = UUID()
    // Every change to the library goes through this one queue, in the order you made it.
    let queue: EditQueue
    let navigation: WorkshopNavigation
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let search: SearchState
    let jobList: JobListState
    let partList: PartListState
    let notes: RecordNotesState
    let checklist: ChecklistState
    let parts: PartState
    let money: MoneyState
    let material: MaterialState
    let editing: WorkshopEditing
    let bench: BenchReferenceState

    init(coordinator: LibraryCoordinator, configuration: AppConfiguration) {
        queue = EditQueue(coordinator: coordinator)
        navigation = WorkshopNavigation(configuration: configuration)
        watches = WatchState(queue: queue)
        calibers = CaliberState(queue: queue)
        jobs = JobState(queue: queue)
        checklist = ChecklistState(queue: queue)
        let money = MoneyState(service: MoneyService(coordinator: coordinator), queue: queue)
        self.money = money
        parts = PartState(
            service: PartService(coordinator: coordinator), queue: queue,
            home: { [money] in money.home })
        // Weak, because the parts already hold the money state through their home currency.
        money.homeChanged = { [weak parts] in parts?.homeCurrencyChanged() }
        notes = RecordNotesState(queue: queue)
        material = MaterialState(
            service: MaterialService(coordinator: coordinator), queue: queue)
        editing = WorkshopEditing(
            queue: queue, watches: watches, calibers: calibers, jobs: jobs, notes: notes,
            material: material, checklist: checklist, parts: parts)
        search = SearchState(coordinator: coordinator)
        jobList = JobListState(coordinator: coordinator)
        partList = PartListState(coordinator: coordinator)
        bench = BenchReferenceState(
            service: BenchReferenceService(coordinator: coordinator),
            preferences: BenchPreferences(libraryRoot: configuration.libraryRoot))
    }

    func prepareForRestore() {
        bench.stop()
        bench.clearForRestore()
        queue.discardUndo()
    }
}
