nonisolated enum WorkshopSection: String, CaseIterable, Identifiable, Sendable {
    case workshop
    case watches
    case calibers
    case parts
    case archive

    var id: Self { self }

    var title: String {
        switch self {
        case .workshop: "Workshop"
        case .watches: "Watches"
        case .calibers: "Calibers"
        case .parts: "Parts"
        case .archive: "Archive"
        }
    }

    var symbol: String {
        switch self {
        case .workshop: "wrench.and.screwdriver"
        case .watches: "watch.analog"
        case .calibers: "gearshape.2"
        case .parts: "shippingbox"
        case .archive: "archivebox"
        }
    }

    var shortcut: Character {
        switch self {
        case .workshop: "1"
        case .watches: "2"
        case .calibers: "3"
        case .parts: "4"
        case .archive: "5"
        }
    }
}
