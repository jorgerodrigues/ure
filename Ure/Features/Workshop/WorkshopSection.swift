// The four sections of the sidebar, in its order: Workshop holds Jobs and Parts, and Library
// holds Watches and Calibers. ⌘1 to ⌘4 select them in that order.
nonisolated enum WorkshopSection: String, CaseIterable, Identifiable, Sendable {
    case jobs
    case parts
    case watches
    case calibers

    var id: Self { self }

    var title: String {
        switch self {
        case .jobs: "Jobs"
        case .parts: "Parts"
        case .watches: "Watches"
        case .calibers: "Calibers"
        }
    }

    var symbol: String {
        switch self {
        case .jobs: "wrench.adjustable"
        case .parts: "shippingbox"
        case .watches: "watch.analog"
        case .calibers: "smallcircle.filled.circle"
        }
    }

    var group: WorkshopSectionGroup {
        switch self {
        case .jobs, .parts: .workshop
        case .watches, .calibers: .library
        }
    }

    var shortcut: Character {
        switch self {
        case .jobs: "1"
        case .parts: "2"
        case .watches: "3"
        case .calibers: "4"
        }
    }
}

// The two groups of the sidebar: the work on the bench, and what you know and hold.
nonisolated enum WorkshopSectionGroup: CaseIterable, Identifiable, Sendable {
    case workshop
    case library

    var id: Self { self }

    var title: String {
        switch self {
        case .workshop: "Workshop"
        case .library: "Library"
        }
    }

    var sections: [WorkshopSection] { WorkshopSection.allCases.filter { $0.group == self } }
}
