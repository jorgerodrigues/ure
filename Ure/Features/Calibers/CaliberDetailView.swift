import SwiftUI

struct CaliberDetailView: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(MaterialState.self) private var material

    var body: some View {
        if let caliber = calibers.selectedCaliber, material.isPresenting(on: .caliber(caliber.id)) {
            MaterialViewerView(page: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber {
            CaliberPage(caliber: caliber)
        } else {
            ContentUnavailableView {
                Label("Select a caliber", systemImage: "gearshape.2")
            } description: {
                Text(calibers.saveError ?? "Choose a caliber or add a new one.")
            }
        }
    }
}

// A caliber page you write on: its facts, the watches that use it, its material and its notes.
// Each fact saves as you type, with no Save or Cancel.
private struct CaliberPage: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    let caliber: CaliberRecord

    var body: some View {
        Form {
            RecordHeading(title: caliber.title, subtitle: edited)
            Section {
                if caliber.archivedAt != nil {
                    Label("Archived. Unarchive to make changes.", systemImage: "archivebox")
                }
                Button(
                    caliber.archivedAt == nil ? "Archive Caliber" : "Unarchive Caliber",
                    action: toggleArchive
                )
                .disabled(editing.isSaving)
                .accessibilityIdentifier("archiveCaliber")
                if let error = calibers.saveError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section("Facts") {
                if let facts = calibers.facts(for: caliber.id) {
                    CaliberFactRows(caliberID: caliber.id, facts: facts).id(caliber.id)
                }
            }
            Section("Watches") {
                CaliberWatches(caliberID: caliber.id)
            }
            MaterialSectionView(owner: .caliber(caliber.id))
            NotesSectionView(owner: .caliber(caliber.id))
        }
        .formStyle(.grouped)
        .navigationTitle(navigation.selectedSection.title)
    }

    private var edited: String {
        "Edited \(caliber.updatedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func toggleArchive() { editing.requestNavigation(calibers.toggleArchiveCommand) }
}

private struct CaliberFactRows: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    let caliberID: UUID
    let facts: CaliberFacts

    // While the caliber archives, its facts can't change, so the archive's save covers them.
    var body: some View {
        let isEditable = editing.canWrite(.caliber(caliberID)) && !calibers.isSaving
        FactRow(
            field: facts.name, isEditable: isEditable, identifier: "caliberName",
            requestsFocus: calibers.nameToFocus == caliberID, didFocus: calibers.nameFocused)
        FactRow(field: facts.maker, isEditable: isEditable, identifier: "caliberMaker")
        FactRow(field: facts.winding, isEditable: isEditable, identifier: "caliberWinding")
        FactRow(field: facts.beatRate, isEditable: isEditable, identifier: "caliberBeatRate")
        FactRow(field: facts.jewels, isEditable: isEditable, identifier: "caliberJewels")
        FactRow(
            field: facts.powerReserve, isEditable: isEditable, identifier: "caliberPowerReserve")
        FactRow(field: facts.liftAngle, isEditable: isEditable, identifier: "caliberLiftAngle")
    }
}

private struct CaliberWatches: View {
    @Environment(WatchState.self) private var watches
    let caliberID: UUID

    var body: some View {
        if watches.isLoading {
            ProgressView("Loading watches…")
        } else if let error = watches.loadError {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry", action: retry)
        } else if linkedWatches.isEmpty {
            Text("No watches use this caliber.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(linkedWatches) { watch in
                CaliberWatchLink(watch: watch)
            }
        }
    }

    private var linkedWatches: [WatchRecord] {
        watches.watches.filter { $0.caliberID == caliberID }
    }

    private func retry() {
        Task { await watches.observe() }
    }
}

private struct CaliberWatchLink: View {
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        Button(watch.name, action: openWatch)
            .accessibilityIdentifier("caliberWatch-\(watch.id)")
    }

    private func openWatch() {
        editing.requestNavigation {
            editing.jobs.close()
            watches.searchText = ""
            watches.select(watch.id)
            navigation.selection = .watches
        }
    }
}
