import SwiftUI

struct WorkshopSidebar: View {
    @Environment(SearchState.self) private var search
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        List(WorkshopSection.allCases, selection: selection) { section in
            Label(section.title, systemImage: section.symbol)
                .tag(section)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workshop sections")
        .disabled(editing.isSaving)
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
