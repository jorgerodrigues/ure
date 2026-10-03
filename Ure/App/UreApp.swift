import SwiftUI

@main
struct UreApp: App {
    @NSApplicationDelegateAdaptor(WorkshopApplicationDelegate.self) private var applicationDelegate
    @State private var navigation: WorkshopNavigation
    @State private var library: LibraryState
    @State private var watches: WatchState
    @State private var calibers: CaliberState
    @State private var jobs: JobState
    @State private var notes: NoteState
    @State private var references: ReferenceState
    @State private var photos: PhotoState
    @State private var documents: DocumentState
    @State private var editing: WorkshopEditing
    @State private var bench: BenchReferenceState

    init() {
        let configuration = AppConfiguration.current
        #if DEBUG
            let dependencies = LibraryTestSeed.dependencies(
                environment: ProcessInfo.processInfo.environment)
        #else
            let dependencies = LibraryDependencies()
        #endif
        _navigation = State(initialValue: WorkshopNavigation(configuration: configuration))
        let coordinator = LibraryCoordinator(
            root: configuration.libraryRoot, dependencies: dependencies)
        let watches = WatchState(service: WatchService(coordinator: coordinator))
        let calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let notes = NoteState(service: NoteService(coordinator: coordinator))
        let references = ReferenceState(service: ReferenceService(coordinator: coordinator))
        let photos = PhotoState(service: PhotoService(coordinator: coordinator))
        let documents = DocumentState(service: DocumentService(coordinator: coordinator))
        let editing = WorkshopEditing(
            watches: watches, calibers: calibers, jobs: jobs, notes: notes, references: references,
            photos: photos, documents: documents)
        _library = State(initialValue: LibraryState(coordinator: coordinator))
        _watches = State(initialValue: watches)
        _calibers = State(initialValue: calibers)
        _jobs = State(initialValue: jobs)
        _notes = State(initialValue: notes)
        _references = State(initialValue: references)
        _photos = State(initialValue: photos)
        _documents = State(initialValue: documents)
        _editing = State(initialValue: editing)
        _bench = State(
            initialValue: BenchReferenceState(
                service: BenchReferenceService(coordinator: coordinator),
                preferences: BenchPreferences(libraryRoot: configuration.libraryRoot)))
        applicationDelegate.editing = editing
    }

    var body: some Scene {
        Window("Ure", id: "workshop") {
            LibraryRootView()
                .environment(navigation)
                .environment(library)
                .environment(watches)
                .environment(calibers)
                .environment(jobs)
                .environment(notes)
                .environment(references)
                .environment(photos)
                .environment(documents)
                .environment(editing)
                .environment(bench)
                .focusedSceneValue(\.allowsWorkshopEditing, true)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            WorkshopCommands(navigation: navigation, editing: editing, bench: bench)
        }

        Window("Reference", id: "reference") {
            ReferenceWindowView(bench: bench)
                .frame(minWidth: 420, minHeight: 650)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}
