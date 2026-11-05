import SwiftUI

// The search field in the toolbar, with the prompt "Search", as on every window artboard. It
// finds within the selected section. ⌘F puts the cursor in it from every section.
private struct ToolbarSearch: ViewModifier {
    @Environment(WorkshopNavigation.self) private var navigation
    @Binding var text: String
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: ToolbarSearchLayout.prompt)
            .searchFocused($isFocused)
            .onChange(of: navigation.searchFocusRequest, focusSearchEffect)
    }

    private func focusSearchEffect() { isFocused = true }
}

enum ToolbarSearchLayout {
    static let prompt = "Search"
}

extension View {
    func toolbarSearch(text: Binding<String>) -> some View {
        modifier(ToolbarSearch(text: text))
    }
}
