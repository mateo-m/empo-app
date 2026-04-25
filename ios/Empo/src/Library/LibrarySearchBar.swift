import SwiftUI

/// Search bar + sort + grid/list toggle shown at the top of the library.
/// Own state stays on GameLibraryView; this view just renders bindings.

struct LibrarySearchBar: View {
    @Binding var searchText: String
    @Binding var showSortSheet: Bool
    let onDisplayModeToggle: () -> Void
    let onSelectMultiple: () -> Void
    /// Hide the Select-multiple icon while the library is already
    /// in selection mode (the header's "Done" button is the exit
    /// affordance). Search / sort / display-mode stay available so
    /// users can find specific games to add to the selection.
    var hideSelectMultiple: Bool = false
    @Environment(\.appSettings) private var settings

    private let searchBarHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search games", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: searchBarHeight)
            .glassEffect(.regular.interactive(), in: .capsule)

            IconButton("arrow.up.arrow.down", style: .outline) {
                showSortSheet = true
            }
            .accessibilityLabel("Sort games")

            IconButton(
                settings.libraryDisplayMode == .grid ? "list.bullet" : "square.grid.2x2",
                style: .outline,
                contentTransition: .symbolEffect(.replace)
            ) {
                onDisplayModeToggle()
            }
            .accessibilityLabel(settings.libraryDisplayMode == .grid ? "Switch to list" : "Switch to grid")

            // Multi-select entry point. Sits in the same row as
            // sort and grid/list because all three are "act on the
            // library" actions. Top-right of the header is owned by
            // the floating ImportButton, so this stays here even
            // though it's the kind of action a user might also
            // expect in the header chrome.
            if !hideSelectMultiple {
                IconButton("checkmark.circle", style: .outline) {
                    onSelectMultiple()
                }
                .accessibilityLabel("Select multiple games")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, Spacing.xs)
        .tint(.primary)
    }
}
