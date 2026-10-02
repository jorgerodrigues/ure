import SwiftUI

struct WorkshopSidebar: View {
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WatchState.self) private var watches

    var body: some View {
        List(WorkshopSection.allCases, selection: selection) { section in
            Label(section.title, systemImage: section.symbol)
                .tag(section)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workshop sections")
        .disabled(watches.isSaving)
    }

    private var selection: Binding<WorkshopSection?> {
        Binding(get: currentSection, set: selectSection)
    }

    private func currentSection() -> WorkshopSection? { navigation.selection }

    private func selectSection(_ section: WorkshopSection?) {
        guard section != navigation.selection else { return }
        watches.requestNavigation { navigation.selection = section }
    }
}
