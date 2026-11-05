import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A record's photos, PDFs and links as tiles, with a strip to add more. A watch or job page
// also shows its caliber's material as chips. That material stays on the caliber.
struct MaterialSectionView: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    @State private var showsImporter = false
    let owner: LibraryItemOwner
    var caliber: CaliberRecord?

    var body: some View {
        Section("Material") {
            if material.isLoading {
                ProgressView("Loading material…")
            } else if let error = material.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                MaterialTiles(owner: owner, isEditable: editing.canWrite(owner))
                if editing.canWrite(owner) {
                    MaterialDropStrip(choose: chooseFiles, drop: addDropped, paste: paste)
                        .disabled(editing.isSaving)
                } else {
                    Text(readOnlyMessage).foregroundStyle(.secondary)
                }
                MaterialImportProgress(owner: owner)
                if let error = material.errors[owner] {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let caliber {
                    CaliberMaterialChips(caliber: caliber, page: owner)
                }
            }
        }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true, onCompletion: pickedFiles)
    }

    private var readOnlyMessage: String {
        if case .job = owner { return "Reopen the job to add or change its material." }
        return "Unarchive this record to add or change its material."
    }

    private func chooseFiles() { editing.requestNavigation { showsImporter = true } }

    private func pickedFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let sources): material.importFiles(sources, for: owner)
        case .failure(let error): material.reportError(error.localizedDescription, on: owner)
        }
    }

    private func addDropped(_ urls: [URL]) {
        guard editing.canWrite(owner), !editing.isSaving else { return }
        Task { await material.add(urls, for: owner) }
    }

    private func paste(_ text: String?) {
        guard editing.canWrite(owner), !editing.isSaving else { return }
        Task { await material.paste(text, for: owner) }
    }

    private func retry() { Task { await material.observe() } }
}

private struct MaterialTiles: View {
    @Environment(MaterialState.self) private var material
    let owner: LibraryItemOwner
    let isEditable: Bool

    private let columns = [
        GridItem(
            .adaptive(minimum: MaterialLayout.tileWidth, maximum: MaterialLayout.tileWidth + 40),
            spacing: MaterialLayout.tileSpacing, alignment: .top)
    ]

    var body: some View {
        let records = material.records(for: owner)
        if records.isEmpty {
            Text("No photos, PDFs or links yet.").foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MaterialLayout.tileSpacing) {
                ForEach(records) { record in
                    MaterialTile(record: record, page: owner, isEditable: isEditable)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct MaterialTile: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    let record: MaterialRecord
    let page: LibraryItemOwner
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                MaterialPreview(record: record)
                    .frame(maxWidth: .infinity)
                    .frame(height: MaterialLayout.previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: MaterialLayout.cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: MaterialLayout.cornerRadius))
            }
            .buttonStyle(.plain)
            .help(openHelp)
            .accessibilityLabel("Open \(record.item.title)")
            .accessibilityIdentifier("material-\(record.id.uuidString)")
            if let field = material.titleField(for: record.id) {
                MaterialTitleView(
                    field: field, text: field.text, isEditable: isEditable,
                    endEditing: material.endEditingTitle)
                if let error = field.saveError {
                    MaterialTitleFailure(message: error, retry: field.saveNow)
                }
            }
            Text(record.item.detailLine())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu { MaterialTileMenu(record: record, page: page, isEditable: isEditable) }
    }

    private var openHelp: String {
        if record.item.kind == .link { return record.item.url ?? "Open in Browser" }
        return "Open \(record.item.kind.title)"
    }

    private func open() { editing.requestNavigation { material.open(record, on: page) } }
}

private struct MaterialTileMenu: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let record: MaterialRecord
    let page: LibraryItemOwner
    let isEditable: Bool

    var body: some View {
        Button(record.item.kind == .link ? "Open in Browser" : "Open", action: open)
        if record.asset != nil {
            Button("Export Original…", action: exportOriginal)
        }
        if record.item.url != nil {
            Button("Copy Link", action: copyLink)
        }
        if isEditable, record.item.belongs(to: page) {
            Divider()
            Button("Remove \(record.item.kind.title)", role: .destructive, action: remove)
                .disabled(editing.isSaving)
        }
    }

    private func open() { editing.requestNavigation { material.open(record, on: page) } }

    private func remove() {
        Task { await material.remove(record, on: page, undoManager: undoManager) }
    }

    private func copyLink() {
        guard let url = record.item.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func exportOriginal() {
        guard let asset = record.asset else { return }
        MaterialExport.choose(asset, from: page, material: material)
    }
}

private struct MaterialPreview: View {
    let record: MaterialRecord

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if record.item.kind == .photo {
                PhotoThumbnailView(photoID: record.id, fills: true)
            } else {
                Image(systemName: record.item.kind.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MaterialTitleFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Label("The title did not save. \(message)", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Button("Try Again", action: retry).controlSize(.mini)
        }
    }
}

private struct MaterialImportProgress: View {
    @Environment(MaterialState.self) private var material
    let owner: LibraryItemOwner

    var body: some View {
        if material.importOwner == owner {
            if material.isImporting {
                HStack {
                    ProgressView("Adding files…").controlSize(.small)
                    Button("Cancel", action: material.cancelImport)
                }
            }
            ForEach(material.importResults) { result in
                MaterialImportResultView(result: result)
            }
        }
    }
}

private struct MaterialImportResultView: View {
    let result: FileImportResult<MaterialRecord>

    var body: some View {
        switch result.outcome {
        case .success:
            Label("\(result.source.lastPathComponent): Added", systemImage: "checkmark.circle")
                .font(.caption)
        case .failure(let error):
            Label(
                "\(result.source.lastPathComponent): \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}

private struct CaliberMaterialChips: View {
    @Environment(MaterialState.self) private var material
    let caliber: CaliberRecord
    let page: LibraryItemOwner

    var body: some View {
        let records = material.records(for: .caliber(caliber.id))
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("From \(caliber.title):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ChipFlowLayout(spacing: 6) {
                    ForEach(records) { record in
                        MaterialChip(record: record, page: page)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Material from \(caliber.title)")
        }
    }
}

private struct MaterialChip: View {
    @Environment(MaterialState.self) private var material
    @Environment(WorkshopEditing.self) private var editing
    let record: MaterialRecord
    let page: LibraryItemOwner

    var body: some View {
        Button(action: open) {
            Label(record.item.title, systemImage: record.item.kind.symbol)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(record.item.detailLine())
        .accessibilityIdentifier("caliberMaterial-\(record.id.uuidString)")
    }

    private func open() { editing.requestNavigation { material.open(record, on: page) } }
}

// Lays chips out in rows that wrap at the available width.
private struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = chipSize(subviews[index], width: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = chipSize(subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width =
                current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    // A chip is never wider than the row, so a long title truncates instead of overflowing.
    private func chipSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

enum MaterialExport {
    static func choose(_ asset: FileAsset, from page: LibraryItemOwner, material: MaterialState) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asset.originalFilename
        panel.canCreateDirectories = true
        panel.title = "Export Original"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            material.export(asset.id, to: destination, from: page)
        }
    }
}

extension LibraryItemKind {
    var symbol: String {
        switch self {
        case .photo: "photo"
        case .document: "doc.richtext"
        case .link: "link"
        }
    }
}

extension LibraryItem {
    // A line such as "Photo · 12 Oct". Material from another year also shows the year.
    func detailLine(now: Date = .now, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if !calendar.isDate(createdAt, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return "\(kind.title) · \(createdAt.formatted(style))"
    }
}
