import Foundation
import Observation

@Observable
final class WorkshopSession {
    let id = UUID()
    let navigation: WorkshopNavigation
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let search: SearchState
    let workshop: WorkshopOverviewState
    let partsOverview: PartsOverviewState
    let notes: RecordNotesState
    let tasks: JobTaskState
    let parts: PartState
    let material: MaterialState
    let editing: WorkshopEditing
    let bench: BenchReferenceState

    init(coordinator: LibraryCoordinator, configuration: AppConfiguration) {
        navigation = WorkshopNavigation(configuration: configuration)
        watches = WatchState(service: WatchService(coordinator: coordinator))
        calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        jobs = JobState(service: JobService(coordinator: coordinator))
        tasks = JobTaskState(service: JobTaskService(coordinator: coordinator))
        parts = PartState(service: PartService(coordinator: coordinator))
        notes = RecordNotesState(service: RecordNotesService(coordinator: coordinator))
        material = MaterialState(service: MaterialService(coordinator: coordinator))
        editing = WorkshopEditing(
            watches: watches, calibers: calibers, jobs: jobs, notes: notes, material: material,
            tasks: tasks, parts: parts)
        search = SearchState(coordinator: coordinator)
        workshop = WorkshopOverviewState(coordinator: coordinator)
        partsOverview = PartsOverviewState(coordinator: coordinator)
        bench = BenchReferenceState(
            service: BenchReferenceService(coordinator: coordinator),
            preferences: BenchPreferences(libraryRoot: configuration.libraryRoot))
    }

    func prepareForRestore() {
        bench.stop()
        bench.clearForRestore()
        notes.discardUndo()
        material.discardUndo()
    }
}
