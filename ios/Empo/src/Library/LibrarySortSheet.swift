import SwiftUI

/// Modal sheet letting the user pick a library sort option. Bound to
/// `AppSettings.librarySortOption` via the injected settings store.

struct LibrarySortSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.appSettings) private var settings

    var body: some View {
        NavigationStack {
            List {
                ForEach(LibrarySortOption.allCases, id: \.self) { option in
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
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(.brand)
    }
}
