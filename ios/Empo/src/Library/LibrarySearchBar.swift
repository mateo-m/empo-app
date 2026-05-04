import SwiftUI

/// Search bar + sort + grid/list toggle shown at the top of the library.
/// Own state stays on GameLibraryView; this view just renders bindings.
/// Multi-select entry now lives in each game's context menu instead.

struct LibrarySearchBar: View {
    @Binding var searchText: String
    @Binding var showSortSheet: Bool
    let onDisplayModeToggle: () -> Void
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
        }
        .padding(.horizontal)
        .padding(.bottom, Spacing.xs)
        .tint(.primary)
    }
}
