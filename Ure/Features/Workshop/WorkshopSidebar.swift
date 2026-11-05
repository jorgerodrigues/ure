import SwiftUI

// The sidebar, as on every window artboard: Workshop with Jobs and Parts, and Library with
// Watches and Calibers, each with a plain count.
struct WorkshopSidebar: View {
    @Environment(SearchState.self) private var search
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    @Environment(JobListState.self) private var jobList
    @Environment(PartsOverviewState.self) private var partsOverview
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers

    var body: some View {
        List(selection: selection) {
            ForEach(WorkshopSectionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        WorkshopSidebarRow(
                            section: section, isSelected: navigation.selection == section,
                            count: count(of: section)
                        )
                        .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workshop sections")
        .disabled(editing.isSaving)
    }

    // Jobs counts the jobs its list shows, Parts the parts still to buy, and Watches and
    // Calibers the records that are not archived. A count shows once its section has loaded.
    private func count(of section: WorkshopSection) -> Int? {
        switch section {
        case .jobs:
            guard !jobList.isLoading, jobList.loadError == nil else { return nil }
            return jobList.listedRows.count
        case .parts:
            guard !partsOverview.isLoading, partsOverview.loadError == nil else { return nil }
            return partsOverview.toBuyCount
        case .watches:
            guard !watches.isLoading, watches.loadError == nil else { return nil }
            return watches.activeCount
        case .calibers:
            guard !calibers.isLoading, calibers.loadError == nil else { return nil }
            return calibers.activeCount
        }
    }

    private var selection: Binding<WorkshopSection?> {
        Binding(get: currentSection, set: selectSection)
    }

    private func currentSection() -> WorkshopSection? { navigation.selection }

    private func selectSection(_ section: WorkshopSection?) {
        guard search.isPresented || section != navigation.selection else { return }
        editing.requestNavigation {
            search.close(); navigation.selection = section
        }
    }
}
