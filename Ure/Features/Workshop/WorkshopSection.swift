nonisolated enum WorkshopSection: String, CaseIterable, Identifiable, Sendable {
    case workshop
    case watches
    case calibers
    case parts

    var id: Self { self }

    var title: String {
        switch self {
        case .workshop: "Workshop"
        case .watches: "Watches"
        case .calibers: "Calibers"
        case .parts: "Parts"
        }
    }

    var symbol: String {
        switch self {
        case .workshop: "wrench.and.screwdriver"
        case .watches: "watch.analog"
        case .calibers: "gearshape.2"
        case .parts: "shippingbox"
        }
    }

    var shortcut: Character {
        switch self {
        case .workshop: "1"
        case .watches: "2"
        case .calibers: "3"
        case .parts: "4"
        }
    }
}
