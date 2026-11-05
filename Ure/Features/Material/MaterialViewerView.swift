import SwiftUI

// Shows a photo in the photo viewer or a PDF in the PDF reader, in place of the record page it
// was opened from.
struct MaterialViewerView: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let page: LibraryItemOwner

    var body: some View {
        Group {
            if let record = material.presentedRecord {
                GeometryReader { geometry in
                    ScrollView {
                        MaterialViewerContent(
                            record: record, page: page,
                            viewerHeight: max(360, geometry.size.height * 0.7))
                    }
                }
                .padding()
                .navigationTitle(record.item.title)
                .toolbar {
                    if canRemove(record) {
                        Button(
                            "Remove \(record.item.kind.title)", role: .destructive, action: remove
                        )
                        .disabled(editing.isSaving)
                        .accessibilityIdentifier("removeMaterial")
                    }
                    Button("Export Original", action: exportOriginal)
                        .disabled(editing.isSaving || record.asset == nil)
                }
            } else {
                ContentUnavailableView("Material unavailable", systemImage: "photo")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(page.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromMaterial")
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }

    private func canRemove(_ record: MaterialRecord) -> Bool {
        editing.canWrite(page) && material.canRemove(record, on: page)
    }

    private var menuActions: RecordMenuActions {
        guard let record = material.presentedRecord, !editing.isSaving else {
            return RecordMenuActions()
        }
        var actions = RecordMenuActions()
        if record.asset != nil { actions.exportOriginal = exportOriginal }
        if canRemove(record) { actions.remove = remove }
        return actions
    }

    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return back
    }

    private func back() { editing.requestNavigation(material.close) }

    private func remove() {
        guard let record = material.presentedRecord else { return }
        Task { await material.remove(record, on: page, undoManager: undoManager) }
    }

    private func exportOriginal() {
        guard let asset = material.presentedRecord?.asset else { return }
        MaterialExport.choose(asset, from: page, material: material)
    }
}

private struct MaterialViewerContent: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    let record: MaterialRecord
    let page: LibraryItemOwner
    let viewerHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if record.item.kind == .photo {
                    Button("Previous", systemImage: "chevron.left", action: previous)
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        .disabled(!material.canMove(by: -1) || editing.isSaving)
                    Button("Next", systemImage: "chevron.right", action: next)
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .disabled(!material.canMove(by: 1) || editing.isSaving)
                }
                Spacer()
                Text(context).foregroundStyle(.secondary)
            }
            if let asset = record.asset {
                if record.item.kind == .photo {
                    PhotoViewerView(reader: material.reader, assetID: asset.id)
                        .id(asset.id)
                        .frame(height: viewerHeight)
                } else {
                    DocumentViewerView(source: material.reader, assetID: asset.id)
                        .id(asset.id)
                        .frame(height: viewerHeight)
                }
                Text(asset.originalFilename).font(.caption).textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "Original unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("This material's original file is missing."))
            }
            if let error = material.errors[page] {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private var context: String {
        guard let owner = record.item.owner, owner != page else { return record.item.detailLine() }
        return "\(owner.scope) · \(record.item.detailLine())"
    }

    private func previous() { material.moveSelection(by: -1) }
    private func next() { material.moveSelection(by: 1) }
}
