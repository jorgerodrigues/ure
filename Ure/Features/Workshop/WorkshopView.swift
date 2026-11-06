import AppKit
import Combine
import SwiftUI

struct WorkshopView: View {
    @Environment(SearchState.self) private var search
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(JobState.self) private var jobs
    @Environment(JobListState.self) private var jobList
    @Environment(PartListState.self) private var partList
    @Environment(ChecklistState.self) private var checklist
    @Environment(PartState.self) private var parts
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    @Environment(BenchReferenceState.self) private var bench
    @Environment(\.openWindow) private var openWindow
    @State private var didRestoreSelection = false

    var body: some View {
        NavigationSplitView {
            WorkshopSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: UreLayout.sidebarWidth, max: 260)
        } content: {
            Group {
                if search.isPresented {
                    SearchView()
                } else if navigation.selectedSection == .jobs {
                    JobListView()
                } else if navigation.selectedSection == .watches {
                    WatchListView()
                } else if navigation.selectedSection == .calibers {
                    CaliberListView()
                } else {
                    PartListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: UreLayout.listWidth, max: 400)
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
        .task(id: jobList.observationRevision, jobList.observe)
        .task(id: partList.observationRevision, partList.observe)
        .task(checklist.observe)
        .task(parts.observe)
        .task(material.observe)
        .task(startBench)
        .onChange(of: jobs.selectedID, selectBenchJob)
        .onChange(of: isLoadingSelection, restoreSelection)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: revalidateReference
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .receive(on: RunLoop.main),
            perform: refreshJobDay
        )
        .toolbar {
            if hasActiveJob {
                ToolbarItemGroup(placement: .primaryAction) {
                    BenchPinMenu(bench: bench)
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
    }

    @ViewBuilder private var detail: some View {
        if navigation.selectedSection == .jobs {
            Group {
                if jobs.selectedID == nil {
                    // A New Job that did not save says why here, since no job is selected.
                    ContentUnavailableView(
                        "Select a job", systemImage: WorkshopSection.jobs.symbol,
                        description: Text(
                            jobs.saveError ?? "Choose a job, or start one with New Job."))
                } else {
                    JobDetailView()
                }
            }
            .safeAreaInset(edge: .top) {
                if let message = jobList.selectionMessage(for: jobs.selectedJob) {
                    HStack {
                        Text(message).font(.callout)
                        if jobList.contains(jobs.selectedID) {
                            Button("Clear Search", action: jobList.clearSearch)
                        }
                    }
                    .padding()
                    .accessibilityIdentifier("jobListSelectionMessage")
                }
            }
        } else if navigation.selectedSection == .parts {
            if parts.selectedPart != nil {
                PartDetailView()
            } else {
                ContentUnavailableView(
                    "Select a part", systemImage: WorkshopSection.parts.symbol,
                    description: Text(
                        parts.saveError ?? "Choose a part, or make a spare with New Part."))
            }
        } else if navigation.selectedSection == .watches {
            WatchDetailView()
        } else {
            CaliberDetailView()
        }
    }

    // A job page is open: in Jobs whenever a job is selected, and in Watches when the selected
    // watch shows its job. Parts shows a part's own page.
    private var hasActiveJob: Bool {
        switch navigation.selectedSection {
        case .calibers, .parts: return false
        case .jobs: return jobs.selectedID != nil
        case .watches: return jobs.selectedID != nil && jobs.watchID == watches.selectedID
        }
    }
    private var isLoadingSelection: Bool {
        bench.isLoading || watches.isLoading || jobs.isLoading || jobList.isLoading
    }

    private func startBench() async { bench.start(); restoreSelection() }
    private func selectBenchJob() { bench.selectJob(jobs.selectedID) }
    // Opens the job you worked on last. It opens in Jobs while the list holds it, and on its
    // watch's page once it is older.
    private func restoreSelection() {
        guard !didRestoreSelection, !isLoadingSelection else { return }
        didRestoreSelection = true
        guard !editing.isSaving,
            navigation.selectedSection == .jobs, calibers.selectedID == nil,
            parts.selectedID == nil,
            watches.selectedID == nil, jobs.selectedID == nil,
            let job = jobs.jobs.first(where: { $0.id == bench.jobID })
        else { return }
        watches.select(job.watchID)
        jobs.open(job)
        if !jobList.contains(job.id), job.watchID != nil { navigation.selection = .watches }
    }
    private func revalidateReference(_ notification: Notification) {
        bench.revalidate()
        jobList.refreshDay()
    }
    private func refreshJobDay(_ notification: Notification) { jobList.refreshDay() }
    private func openReference() { openWindow(id: "reference") }
}
