import SwiftUI


struct HintBanner: View {
    let hint: Hint
    @Environment(\.hintStore) private var store

    @State private var showDetail = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: hint.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)

            Text(hint.excerpt)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hint.hasDetail {
                Button("More") { showDetail = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.brand)
            }

            if hint.isDismissable {
                Button {
                    withAnimation(Motion.standard) {
                        store.dismiss(hint)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.brand.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss hint")
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.brand.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .sheet(isPresented: $showDetail) {
            if let description = hint.description {
                HintDetailSheet(excerpt: hint.excerpt, description: description)
            }
        }
    }
}


private struct HintDetailSheet: View {
    let excerpt: String
    let description: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    Label(excerpt, systemImage: "lightbulb.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(description)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing._2xl)
                .padding(.top, Spacing.xl)
            }
            .navigationTitle("Hint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.brand)
                }
            }
        }
    }
}
