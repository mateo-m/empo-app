import SwiftUI

/// Modal sheet letting the user pick a library sort option. Bound to
/// `AppSettings.librarySortOption` via the injected settings store.

struct LibrarySortSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.appSettings) private var settings

    var body: some View {
        NavigationStack {
            List {
                ForEach(LibrarySortOption.groups) { group in
                    Section(group.title) {
                        ForEach(group.options, id: \.self) { option in
                            row(for: option)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(.brand)
    }

    private func row(for option: LibrarySortOption) -> some View {
        Button {
            withAnimation(Motion.standard) {
                settings.librarySortOption = option
            }
            isPresented = false
        } label: {
            HStack(spacing: Spacing.lg) {
                Image(systemName: option.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(option.label)
                Spacer()
                if settings.librarySortOption == option {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.brand)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(.primary)
    }
}
