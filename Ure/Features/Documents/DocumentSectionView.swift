import SwiftUI
import UniformTypeIdentifiers

struct DocumentSectionView: View {
    @State private var searchText = ""
    @Environment(DocumentState.self) private var documents
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @State private var showsImporter = false
    @State private var pickerError: String?
    let owner: LibraryItemOwner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Import PDFs", systemImage: "doc.badge.plus", action: chooseFiles)
                .disabled(editing.isSaving || !editing.canWrite(owner))
                .accessibilityIdentifier("importDocuments")
            Text(
                "Choose or drop PDF files here. Up to 200 files, 100 MB each. Protected PDFs are unsupported."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !editing.canWrite(owner) {
                Text("Unarchive the owner or reopen the job to import or edit documents.")
                    .foregroundStyle(.secondary)
            }
            if documents.isLoading {
                ProgressView("Loading documents…")
            } else if let error = documents.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                if let error = pickerError { Label(error, systemImage: "exclamationmark.triangle") }
                if documents.importOwner == owner {
                    if documents.isImporting {
                        ProgressView("Importing documents…")
                        Button("Cancel Import", action: documents.cancelImport)
                    }
                    ForEach(documents.importResults) { result in
                        DocumentImportResultView(result: result)
                    }
                }
                TextField("Filter PDFs by title or caption", text: $searchText)
                    .accessibilityIdentifier("documentsLocalSearch")
                if documents.records(for: owner, matching: searchText).isEmpty {
                    Text(searchText.isEmpty ? "No PDFs yet." : "No matching PDFs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(documents.records(for: owner, matching: searchText)) { document in
                    DocumentRow(document: document, owner: owner)
                }
            }
        }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true, onCompletion: pickedFiles
        )
        .dropDestination(for: URL.self, action: droppedFiles)
    }

    private func chooseFiles() { editing.requestNavigation { showsImporter = true } }
    private func pickedFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let sources): beginImport(sources)
        case .failure(let error): pickerError = error.localizedDescription
        }
    }
    private func droppedFiles(_ sources: [URL], _ location: CGPoint) -> Bool {
        guard !sources.isEmpty, !editing.isSaving, editing.canWrite(owner) else {
            return false
        }
        beginImport(sources)
        return true
    }
    private func beginImport(_ sources: [URL]) {
        guard editing.canWrite(owner) else { return }
        pickerError = nil
        editing.requestNavigation { documents.importFiles(sources, for: owner) }
    }
    private func retry() { Task { await documents.observe() } }
}

private struct DocumentImportResultView: View {
    let result: FileImportResult<DocumentRecord>
    var body: some View {
        switch result.outcome {
        case .success:
            Label("\(result.source.lastPathComponent): Imported", systemImage: "checkmark.circle")
                .font(.caption)
        case .failure(let error):
            Label(
                "\(result.source.lastPathComponent): \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(.red)
        }
    }
}

private struct DocumentRow: View {
    @Environment(DocumentState.self) private var documents
    @Environment(WorkshopEditing.self) private var editing
    let document: DocumentRecord
    let owner: LibraryItemOwner

    var body: some View {
        Button(action: select) {
            HStack {
                Text(document.item.title)
                Spacer()
                Label("PDF · Offline", systemImage: "doc.richtext").foregroundStyle(.secondary)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("document-\(document.id.uuidString)")
    }

    private func select() { editing.requestNavigation { documents.open(document, for: owner) } }
}
