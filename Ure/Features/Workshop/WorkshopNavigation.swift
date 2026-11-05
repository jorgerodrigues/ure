import Observation

@Observable
final class WorkshopNavigation {
    let configuration: AppConfiguration
    var selection: WorkshopSection? = .jobs
    // ⌘F asks the toolbar's search field to take the cursor. The field clears this once it has.
    var searchFocusRequest = 0

    var selectedSection: WorkshopSection {
        selection ?? .jobs
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func focusSearch() { searchFocusRequest += 1 }
}
