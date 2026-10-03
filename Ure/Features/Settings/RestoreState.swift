import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class RestoreState {
    let library: LibraryState
    private(set) var session: WorkshopSession
    private(set) var backup: BackupState
    private(set) var staged: StagedRestore?
    private(set) var isStaging = false
    private(set) var isActivating = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    private(set) var recoveryDirectory: URL?
    var showsConfirmation = false
    private let configuration: AppConfiguration
    private var operation: Task<Void, Never>?
    private var panel: NSOpenPanel?
    private var pendingConfirmation: StagedRestore?

    init(library: LibraryState, configuration: AppConfiguration) {
        self.library = library
        self.configuration = configuration
        session = WorkshopSession(coordinator: library.coordinator, configuration: configuration)
        backup = BackupState(coordinator: library.coordinator)
    }

    var isBusy: Bool { isStaging || isActivating }
    var canRestore: Bool {
        guard case .ready = library.phase else { return false }
        return !isBusy && !backup.isExporting && !session.editing.isSaving
            && !session.editing.hasUnsavedChanges && !session.editing.isNavigationPending
    }

    func chooseBackup() {
        guard canRestore, staged == nil, panel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore Library Backup"
        panel.prompt = "Review Backup"
        panel.allowedContentTypes = [
            UTType(exportedAs: "local.ure.watchbackup", conformingTo: .package)
        ]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        self.panel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.panel = nil
            if response == .OK, let package = panel.url { self.stage(from: package) }
        }
    }

    func stage(from package: URL) {
        guard canRestore, staged == nil else { return }
        isStaging = true
        message = nil
        errorMessage = nil
        let coordinator = library.coordinator
        operation = Task {
            defer { isStaging = false; operation = nil }
            do {
                let result = try await coordinator.stageRestore(from: package)
                if Task.isCancelled {
                    try await coordinator.discardRestore(result)
                    message = "Restore cancelled. The current library was kept."
                } else {
                    staged = result
                }
            } catch is CancellationError {
                message = "Restore cancelled. The current library was kept."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard !isActivating else { return }
        if isStaging { operation?.cancel(); return }
        guard let staged else { return }
        self.staged = nil
        pendingConfirmation = nil
        showsConfirmation = false
        isStaging = true
        let coordinator = library.coordinator
        operation = Task {
            defer { isStaging = false; operation = nil }
            do {
                try await coordinator.discardRestore(staged)
                message = "Restore cancelled. The current library was kept."
            } catch {
                self.staged = staged
                errorMessage =
                    "The unused restore copy could not be removed. The current library was kept."
            }
        }
    }

    func requestConfirmation() {
        guard canRestore, let staged else { return }
        pendingConfirmation = staged
        showsConfirmation = true
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
        showsConfirmation = false
    }

    func confirm() {
        guard canRestore, let staged, pendingConfirmation == staged else { return }
        pendingConfirmation = nil
        showsConfirmation = false
        isActivating = true
        errorMessage = nil
        let coordinator = library.coordinator
        self.staged = nil
        session.prepareForRestore()
        library.beginRestore()
        operation = Task {
            defer { isActivating = false; operation = nil }
            do {
                let result = try await coordinator.activateRestore(staged)
                recoveryDirectory = result.recovery?.directory
                self.staged = result.candidate
                library.finishRestore(result)
                session = WorkshopSession(
                    coordinator: library.coordinator, configuration: configuration)
                backup = BackupState(coordinator: library.coordinator)
                if case .restored = result.outcome {
                    message = result.message
                } else {
                    errorMessage = result.message
                }
                if result.library != nil { await backup.refresh() }
            } catch {
                self.staged = staged
                library.restoreFailedBeforeActivation(error.localizedDescription)
                errorMessage =
                    "Restore could not start. The current library was kept. \(error.localizedDescription)"
            }
        }
    }

    func revealRecovery() {
        guard let recoveryDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryDirectory])
    }

    func waitForCompletion() async { await operation?.value }

    func discardForTermination() async -> Bool {
        if isStaging {
            operation?.cancel()
            await waitForCompletion()
        }
        if staged != nil {
            cancel()
            await waitForCompletion()
        }
        return staged == nil && !isBusy
    }
}
