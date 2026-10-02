import AppKit
import SwiftUI

struct DocumentDetailView: View {
    @Environment(DocumentState.self) private var documents
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        Group {
            if documents.draft != nil {
                DocumentEditorView(owner: owner)
            } else if let document = documents.selectedDocument {
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(owner.scope) PDF · Available offline", systemImage: "doc.richtext")
                        .foregroundStyle(.secondary)
                    DocumentViewerView(assetID: document.asset.id).id(document.asset.id)
                    ScrollView {
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
                    }
                    .textSelection(.enabled).frame(maxHeight: 130)
                    if let error = documents.operationError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if !documents.canWrite(owner, jobs: jobs) {
                        Text("This job is closed. Reopen it to edit this document.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .navigationTitle(document.item.title)
                .toolbar {
                    Button("Edit Document", action: edit)
                        .disabled(editing.isSaving || !documents.canWrite(owner, jobs: jobs))
                    Button("Export Original", action: exportOriginal).disabled(editing.isSaving)
                }
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc.richtext")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
            }
        }
    }

    private func back() { editing.requestNavigation(documents.close) }
    private func edit() {
        guard documents.canWrite(owner, jobs: jobs) else { return }
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
