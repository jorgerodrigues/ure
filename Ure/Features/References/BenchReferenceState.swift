import Foundation
import GRDB
import Observation

@Observable
final class BenchReferenceState {
    private let service: BenchReferenceService
    private let preferences: BenchPreferences
    let reader: ReferenceReader
    private(set) var snapshot = BenchSnapshot()
    private(set) var jobID: UUID?
    private(set) var pinnedID: UUID?
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var pinMessage: String?
    private(set) var showsPane: Bool
    private var didRestore = false
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(service: BenchReferenceService, preferences: BenchPreferences) {
        self.service = service
        self.preferences = preferences
        reader = ReferenceReader(coordinator: service.coordinator)
        showsPane = preferences.value.showsPane
    }

    var choices: [BenchReference] { snapshot.references(for: jobID) }
    var reference: BenchReference? { choices.first { $0.id == pinnedID } }

    func start() {
        guard observation == nil else { return }
        observation = Task { await observe() }
    }

    func stop() { observation?.cancel(); observation = nil }

    func clearForRestore() {
        jobID = nil
        pinnedID = nil
        snapshot = BenchSnapshot()
        didRestore = true
        persist()
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.benchValues()
            for try await value in values {
                apply(value)
                await validatePin()
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
            clearPin(message: "The reference is unavailable. Retry opening the reference pane.")
        }
    }

    func apply(_ value: BenchSnapshot) {
        snapshot = value
        isLoading = false
        if !didRestore {
            didRestore = true
            let saved = preferences.value
            if jobID == nil, snapshot.jobs.contains(where: { $0.id == saved.jobID }) {
                jobID = saved.jobID
                pinnedID = saved.itemID
            }
        }
        if let jobID, !snapshot.jobs.contains(where: { $0.id == jobID }) {
            self.jobID = nil
        }
        if pinnedID != nil && reference == nil {
            clearPin(message: "The pinned reference is no longer available for this job.")
        }
        persist()
    }

    func selectJob(_ id: UUID?) {
        guard let id, id != jobID else { return }
        jobID = id
        if snapshot.jobs.contains(where: { $0.id == id }), pinnedID != nil && reference == nil {
            clearPin(message: "The pin was cleared because it belongs to another job or watch.")
        }
        persist()
    }

    func pin(_ id: UUID) {
        guard choices.contains(where: { $0.id == id }) else { return }
        pinnedID = id
        pinMessage = nil
        showsPane = true
        persist()
        revalidate()
    }

    func clearPin() { clearPin(message: nil) }

    private func clearPin(message: String?) {
        pinnedID = nil
        pinMessage = message
        persist()
    }

    func togglePane() {
        showsPane.toggle()
        persist()
        if loadError != nil { stop(); start() }
        revalidate()
    }

    func revalidate() { Task { await validatePin() } }

    func validatePin() async {
        guard let selected = reference else { return }
        do {
            try await service.validate(selected)
        } catch {
            guard !Task.isCancelled, reference == selected else { return }
            clearPin(message: "The pinned original is unavailable. Choose another reference.")
        }
    }

    private func persist() {
        preferences.value = BenchPreference(jobID: jobID, itemID: pinnedID, showsPane: showsPane)
    }
}
