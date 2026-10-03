import AppKit
import SwiftUI

struct WorkshopView: View {
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopOverviewState.self) private var workshop
    @Environment(NoteState.self) private var notes
    @Environment(JobTaskState.self) private var tasks
    @Environment(PartState.self) private var parts
    @Environment(ReferenceState.self) private var references
    @Environment(DocumentState.self) private var documents
    @Environment(PhotoState.self) private var photos
    @Environment(WorkshopEditing.self) private var editing
    @Environment(BenchReferenceState.self) private var bench
    @Environment(\.openWindow) private var openWindow
    @State private var didRestoreSelection = false

    var body: some View {
        @Bindable var editing = editing

        NavigationSplitView {
            WorkshopSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            Group {
                if navigation.selectedSection == .workshop {
                    WorkshopOverviewView()
                } else if navigation.selectedSection == .watches {
                    WatchListView()
                } else if navigation.selectedSection == .calibers {
                    CaliberListView()
                } else {
                    WorkshopSectionView(section: navigation.selectedSection)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom) {
                            if hasActiveJob, bench.reference != nil, bench.showsPane,
                                !BenchLayout.showsPane(
                                    availableWidth: geometry.size.width, requested: true)
                            {
                                HStack {
                                    Text("Widen the window to show the pinned reference.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open Reference Window", action: openReference)
                                }.padding()
                            }
                        }
                    if hasActiveJob
                        && BenchLayout.showsPane(
                            availableWidth: geometry.size.width, requested: bench.showsPane)
                    {
                        Divider()
                        BenchPaneView().frame(width: BenchLayout.referenceWidth)
                    }
                }
            }
        }
        .task(watches.observe)
        .task(calibers.observe)
        .task(jobs.observe)
        .task(id: workshop.observationRevision, workshop.observe)
        .task(notes.observe)
        .task(tasks.observe)
        .task(parts.observe)
        .task(references.observe)
        .task(photos.observe)
        .task(documents.observe)
        .task(startBench)
        .onChange(of: jobs.selectedID, selectBenchJob)
        .onChange(of: isLoadingSelection, restoreSelection)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: revalidateReference
        )
        .toolbar {
            if hasActiveJob {
                ToolbarItemGroup(placement: .primaryAction) {
                    BenchPinMenu()
                        .labelStyle(.iconOnly)
                    Button("Open Reference Window", systemImage: "macwindow", action: openReference)
                        .disabled(bench.reference == nil)
                        .labelStyle(.iconOnly)
                }.visibilityPriority(.low)
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        "Toggle Reference Pane", systemImage: "sidebar.right",
                        action: bench.togglePane
                    )
                    .help("Show the reference pane when there is room beside the editor.")
                    .accessibilityIdentifier("toggleReferencePane")
                }.visibilityPriority(.high)
            }
        }
        .background(WorkshopWindowGuard(editing: editing))
        .alert(editing.unsavedChangesTitle, isPresented: $editing.showsUnsavedChanges) {
            Button("Save", action: editing.saveAndContinueCommand)
            Button("Discard", role: .destructive, action: editing.discardAndContinue)
            Button("Stay", role: .cancel, action: editing.stay)
        } message: {
            Text("Your changes have not been saved.")
        }
    }

    @ViewBuilder private var detail: some View {
        if navigation.selectedSection == .workshop {
            Group {
                if watches.selectedID == nil, watches.draft == nil {
                    ContentUnavailableView(
                        "Select a job", systemImage: "wrench.and.screwdriver",
                        description: Text("Choose an open job to view its details."))
                } else {
                    WatchDetailView()
                }
            }
            .safeAreaInset(edge: .top) {
                if let message = workshop.selectionMessage(for: jobs.selectedJob) {
                    HStack {
                        Text(message).font(.callout)
                        if jobs.selectedJob?.stage.isOpen == true {
                            Button("Clear Filters", action: workshop.clearFilters)
                        }
                    }
                    .padding()
                    .accessibilityIdentifier("workshopSelectionMessage")
                }
            }
        } else if navigation.selectedSection == .watches {
            WatchDetailView()
        } else if navigation.selectedSection == .calibers {
            CaliberDetailView()
        } else {
            ContentUnavailableView(
                "Select a record", systemImage: navigation.selectedSection.symbol,
                description: Text("Choose an item to view its details."))
        }
    }

    private var hasActiveJob: Bool {
        (navigation.selectedSection == .watches || navigation.selectedSection == .workshop)
            && watches.draft == nil
            && jobs.selectedID != nil && jobs.watchID == watches.selectedID
    }
    private var isLoadingSelection: Bool { bench.isLoading || watches.isLoading || jobs.isLoading }

    private func startBench() async { bench.start(); restoreSelection() }
    private func selectBenchJob() { bench.selectJob(jobs.selectedID) }
    private func restoreSelection() {
        guard !didRestoreSelection, !isLoadingSelection else { return }
        didRestoreSelection = true
        guard !editing.hasUnsavedChanges, !editing.isSaving, watches.draft == nil,
            navigation.selectedSection == .workshop, calibers.selectedID == nil,
            calibers.draft == nil, !jobs.isEditing, notes.draft == nil, references.draft == nil,
            photos.draft == nil, documents.draft == nil, tasks.draft == nil, parts.draft == nil,
            watches.selectedID == nil, jobs.selectedID == nil,
            let job = jobs.jobs.first(where: { $0.id == bench.jobID })
        else { return }
        watches.select(job.watchID)
        jobs.open(job)
        navigation.selection = .watches
    }
    private func revalidateReference(_ notification: Notification) { bench.revalidate() }
    private func openReference() { openWindow(id: "reference") }
}
