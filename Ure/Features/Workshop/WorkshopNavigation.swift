import Observation

@Observable
final class WorkshopNavigation {
    let configuration: AppConfiguration
    var selection: WorkshopSection? = .workshop

    var selectedSection: WorkshopSection {
        selection ?? .workshop
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }
}
