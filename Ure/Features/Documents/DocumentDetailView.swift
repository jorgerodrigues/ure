import AppKit
import SwiftUI

struct DocumentDetailView: View {
    @Environment(DocumentState.self) private var documents
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        @Bindable var documents = documents
        Group {
            if documents.draft != nil {
                DocumentEditorView(owner: owner)
            } else if let document = documents.selectedDocument {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(
                                "\(owner.scope) PDF · Available offline",
                                systemImage: "doc.richtext"
                            )
                            .foregroundStyle(.secondary)
                            DocumentViewerView(source: documents.reader, assetID: document.asset.id)
                                .id(
                                    document.asset.id
                                )
                                .frame(height: max(260, geometry.size.height * 0.7))
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent(
                                    "Original filename", value: document.asset.originalFilename)
                                if !document.item.sourceURL.isEmpty {
                                    LabeledContent("Source URL", value: document.item.sourceURL)
                                    Button("Open Source", action: documents.openSource).disabled(
                                        editing.isSaving)
                                }
                                if !document.item.sourceDescription.isEmpty {
                                    LabeledContent("Source", value: document.item.sourceDescription)
                                }
                                if !document.item.notes.isEmpty { Text(document.item.notes) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            if let error = documents.operationError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                            if !editing.canWrite(owner) {
                                Text(
                                    "Unarchive the owner or reopen the job to change this document."
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .navigationTitle(document.item.title)
                .toolbar {
                    Button("Remove Document", role: .destructive, action: requestRemoval)
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                        .accessibilityIdentifier("removeDocument")
                    Button("Edit Document", action: edit)
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                    Button("Export Original", action: exportOriginal).disabled(editing.isSaving)
                }
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc.richtext")
            }
        }
        .alert("Remove this document?", isPresented: $documents.showsRemovalConfirmation) {
            Button("Remove", role: .destructive, action: documents.removeCommand)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This document will be removed. This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = documents.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }

    private var menuActions: RecordMenuActions {
        guard documents.draft == nil, documents.selectedDocument != nil, !editing.isSaving else {
            return RecordMenuActions()
        }
        if editing.canWrite(owner) {
            return RecordMenuActions(
                edit: edit, remove: requestRemoval, exportOriginal: exportOriginal)
        }
        return RecordMenuActions(exportOriginal: exportOriginal)
    }

    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return back
    }

    private func back() { editing.requestNavigation(documents.close) }
    private func requestRemoval() {
        guard editing.canWrite(owner) else { return }
        editing.requestNavigation(documents.requestRemoval)
    }
    private func edit() {
        guard editing.canWrite(owner) else { return }
        documents.edit()
    }
    private func exportOriginal() {
        guard let document = documents.selectedDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.asset.originalFilename
        panel.canCreateDirectories = true
        panel.title = "Export Original"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            documents.export(document.asset.id, to: destination)
        }
    }
}
