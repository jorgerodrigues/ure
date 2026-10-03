import SwiftUI

struct SearchView: View {
    @Environment(SearchState.self) private var search
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            Toggle("Include Archived", isOn: $search.includeArchived)
                .padding()
                .accessibilityIdentifier("includeArchivedSearch")
            if let error = search.navigationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).padding()
            }
            Group {
                if search.isLoading {
                    ProgressView("Searching library…")
                } else if let error = search.loadError {
                    ContentUnavailableView {
                        Label("Search could not load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry", action: search.retry)
                    }
                } else if !search.hasQuery {
                    ContentUnavailableView(
                        "Search Library", systemImage: "magnifyingglass",
                        description: Text(
                            "Find saved text and identifiers. PDF contents and text in images are not searched."
                        ))
                } else if search.results.isEmpty {
                    ContentUnavailableView.search(text: search.text)
                } else {
                    List {
                        ForEach(SearchKind.allCases) { kind in
                            if !search.results(for: kind).isEmpty {
                                Section(kind.rawValue) {
                                    ForEach(search.results(for: kind)) { result in
                                        SearchResultRow(result: result)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("globalSearchResults")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Search")
        .searchable(text: $search.text, prompt: "Find in library")
        .searchFocused($isFocused)
        .task(id: search.request, search.observe)
        .onAppear(perform: activateSearch)
        .toolbar {
            Button("Close Search", systemImage: "xmark", action: search.close)
                .accessibilityIdentifier("closeGlobalSearch")
        }
    }

    private func activateSearch() { isFocused = true }
}

private struct SearchResultRow: View {
    @Environment(SearchState.self) private var search
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let result: SearchResult

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                Text(result.context).font(.caption).foregroundStyle(.secondary)
                if result.isArchived {
                    Text("Archived").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(editing.isSaving || editing.isNavigationPending)
        .accessibilityLabel("\(result.kind.rawValue): \(result.title), \(result.context)")
        .accessibilityIdentifier("searchResult-\(result.id)")
    }

    private func open() { search.open(result.id, editing: editing, navigation: navigation) }
}
