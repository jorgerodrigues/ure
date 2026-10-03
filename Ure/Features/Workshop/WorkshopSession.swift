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
    let notes: NoteState
    let tasks: JobTaskState
    let parts: PartState
    let references: ReferenceState
    let photos: PhotoState
    let documents: DocumentState
    let editing: WorkshopEditing
    let bench: BenchReferenceState

    init(coordinator: LibraryCoordinator, configuration: AppConfiguration) {
        navigation = WorkshopNavigation(configuration: configuration)
        watches = WatchState(service: WatchService(coordinator: coordinator))
        calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        jobs = JobState(service: JobService(coordinator: coordinator))
        tasks = JobTaskState(service: JobTaskService(coordinator: coordinator))
        parts = PartState(service: PartService(coordinator: coordinator))
        notes = NoteState(service: NoteService(coordinator: coordinator))
        references = ReferenceState(service: ReferenceService(coordinator: coordinator))
        photos = PhotoState(service: PhotoService(coordinator: coordinator))
        documents = DocumentState(service: DocumentService(coordinator: coordinator))
        editing = WorkshopEditing(
            watches: watches, calibers: calibers, jobs: jobs, notes: notes, references: references,
            photos: photos, documents: documents, tasks: tasks, parts: parts)
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
    }
}
