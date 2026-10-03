import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class BackupState {
    private(set) var summary: BackupSummary?
    private(set) var isLoading = false
    private(set) var progress: BackupProgress?
    private(set) var lastExport: Date?
    private(set) var message: String?
    private(set) var errorMessage: String?
    private let coordinator: LibraryCoordinator
    private let defaults: UserDefaults
    private let exportKey: String
    private var operation: Task<Void, Never>?
    private var panel: NSSavePanel?

    init(coordinator: LibraryCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
        exportKey = "lastLibraryExport." + coordinator.root.standardizedFileURL.path
        if let saved = defaults.object(forKey: exportKey) as? Date { lastExport = saved }
    }

    var isExporting: Bool { operation != nil }

    var progressLabel: String {
        switch progress {
        case .database: "Copying saved records…"
        case .originals(let completed, let total): "Copying originals: \(completed) of \(total)"
        case .validating: "Checking the complete backup…"
        case .publishing: "Writing the backup package…"
        case nil: "Preparing backup…"
        }
    }

    func refresh() async {
        guard !isLoading, !isExporting else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await coordinator.backupSummary()
            errorMessage = nil
        } catch {
            summary = nil
            errorMessage = error.localizedDescription
        }
    }

    func chooseDestination() {
        guard summary != nil, !isExporting, panel == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Library Backup"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Ure.watchbackup"
        panel.allowedContentTypes = [
            UTType(exportedAs: "local.ure.watchbackup", conformingTo: .package)
        ]
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        self.panel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.panel = nil
            if response == .OK, let destination = panel.url {
                self.export(to: destination)
            }
        }
    }

    func export(to destination: URL) {
        guard !isExporting else { return }
        message = nil
        errorMessage = nil
        progress = .database
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        operation = Task { await performExport(to: destination, version: version) }
    }

    func cancel() {
        guard progress != .publishing else { return }
        operation?.cancel()
    }

    func waitForCompletion() async { await operation?.value }

    private func performExport(to destination: URL, version: String) async {
        let updates = AsyncStream<BackupProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await value in updates.stream {
                if Task.isCancelled { break }
                progress = value
            }
        }
        defer {
            updates.continuation.finish()
            observer.cancel()
            operation = nil
            progress = nil
        }
        do {
            let snapshot = try await coordinator.exportBackup(
                to: destination, applicationVersion: version,
                progress: { value in updates.continuation.yield(value) })
            lastExport = snapshot.createdAt
            defaults.set(snapshot.createdAt, forKey: exportKey)
            message = "Backup exported to \(destination.lastPathComponent)."
        } catch is CancellationError {
            message = "Export cancelled. The previous backup was kept."
        } catch {
            errorMessage = "Export failed. \(error.localizedDescription)"
        }
    }
}
