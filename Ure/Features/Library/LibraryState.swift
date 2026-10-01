import Foundation
import Observation

@Observable
final class LibraryState {
    enum Phase: Equatable {
        case loading
        case ready(LibraryInfo)
        case recovery(String)
    }

    private(set) var phase: Phase = .loading
    let coordinator: LibraryCoordinator
    private var isOpening = false

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
    }

    func open() async {
        guard !isOpening else { return }
        if case .ready = phase { return }
        isOpening = true
        phase = .loading
        defer { isOpening = false }
        do {
            phase = .ready(try await coordinator.open())
        } catch {
            phase = .recovery(error.localizedDescription)
        }
    }
}
