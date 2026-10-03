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
    private(set) var coordinator: LibraryCoordinator
    private var isOpening = false

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
    }

    func beginRestore() { phase = .loading }

    func finishRestore(_ result: RestoreActivation) {
        coordinator = result.coordinator
        if let info = result.library {
            phase = .ready(info)
        } else {
            phase = .recovery(result.message)
        }
    }

    func restoreFailedBeforeActivation(_ reason: String) {
        phase = .recovery(reason)
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
