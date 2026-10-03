import AppKit
import SwiftUI

struct BenchReferenceView: View {
    let reference: BenchReference?
    let reader: ReferenceReader
    var usesKeyboardShortcuts = false
    let onLoadFailure: () -> Void
    @State private var operationError: String?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reference {
                Text(reference.item.title).font(.title3).textSelection(.enabled)
                Label(reference.label, systemImage: "pin.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let asset = reference.asset {
                    if reference.item.kind == .photo {
                        PhotoViewerView(
                            reader: reader, usesKeyboardShortcuts: usesKeyboardShortcuts,
                            onLoadFailure: onLoadFailure, assetID: asset.id
                        )
                        .id(asset.id)
                    } else {
                        DocumentViewerView(
                            source: reader, usesKeyboardShortcuts: usesKeyboardShortcuts,
                            onLoadFailure: onLoadFailure, assetID: asset.id
                        )
                        .id(asset.id)
                    }
                    Text(asset.originalFilename).font(.caption).textSelection(.enabled)
                    Button("Export Original", action: exportOriginal).disabled(isExporting)
                } else {
                    Text("External reference · Linked content is not saved offline.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let caption = reference.item.caption, !caption.isEmpty { Text(caption) }
                        if !reference.item.sourceURL.isEmpty {
                            Text(reference.item.sourceURL)
                            Button("Open in Browser", action: openSource)
                        }
                        if !reference.item.sourceDescription.isEmpty {
                            Text(reference.item.sourceDescription)
                        }
                        if !reference.item.notes.isEmpty { Text(reference.item.notes) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.textSelection(.enabled)
                    .frame(maxHeight: reference.asset == nil ? .infinity : 100)
                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else {
                ContentUnavailableView(
                    "No pinned reference", systemImage: "pin",
                    description: Text("Choose a saved reference in the main window."))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: reference?.id, resetError)
    }

    private func resetError() { operationError = nil }

    private func openSource() {
        guard let reference else { return }
        do { try reader.openSource(reference.item) } catch {
            operationError = error.localizedDescription
        }
    }

    private func exportOriginal() {
        guard !isExporting, let asset = reference?.asset else { return }
        let panel = NSSavePanel()
        panel.title = "Export Original"
        panel.nameFieldStringValue = asset.originalFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            isExporting = true
            Task {
                defer { isExporting = false }
                do { try await reader.export(asset.id, to: destination) } catch {
                    operationError = error.localizedDescription
                }
            }
        }
    }
}

struct BenchPaneView: View {
    @Environment(BenchReferenceState.self) private var bench
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reference").font(.headline)
                Spacer()
                Button("Open Reference Window", systemImage: "macwindow", action: openReference)
                    .disabled(bench.reference == nil)
                Button("Clear Pin", systemImage: "pin.slash", action: bench.clearPin)
                    .disabled(bench.pinnedID == nil)
            }.labelStyle(.iconOnly).padding()
            Divider()
            BenchReferenceView(
                reference: bench.reference, reader: bench.reader, onLoadFailure: bench.revalidate)
            if let message = bench.pinMessage {
                Text(message).foregroundStyle(.secondary).padding()
            }
            if let error = bench.loadError { Text(error).foregroundStyle(.red).padding() }
        }
        .accessibilityIdentifier("benchReferencePane")
    }

    private func openReference() { openWindow(id: "reference") }
}

struct ReferenceWindowView: View {
    let bench: BenchReferenceState

    var body: some View {
        BenchReferenceView(
            reference: bench.reference, reader: bench.reader, usesKeyboardShortcuts: true,
            onLoadFailure: bench.revalidate
        )
        .focusedSceneValue(\.allowsWorkshopEditing, false)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: revalidate)
    }

    private func revalidate(_ notification: Notification) { bench.revalidate() }
}

struct BenchPinMenu: View {
    @Environment(BenchReferenceState.self) private var bench

    var body: some View {
        Menu("Pin Reference", systemImage: "pin") {
            if bench.choices.isEmpty {
                Text("No saved references for this job")
            }
            ForEach(bench.choices) { reference in
                BenchPinButton(reference: reference, bench: bench)
            }
            if bench.pinnedID != nil {
                Divider()
                Button("Clear Pin", action: bench.clearPin)
            }
        }.accessibilityIdentifier("pinReference")
    }
}

private struct BenchPinButton: View {
    let reference: BenchReference
    let bench: BenchReferenceState

    var body: some View {
        Button(reference.label, action: pin)
    }

    private func pin() { bench.pin(reference.id) }
}

struct WorkshopEditingFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var allowsWorkshopEditing: Bool? {
        get { self[WorkshopEditingFocusKey.self] }
        set { self[WorkshopEditingFocusKey.self] = newValue }
    }
}
