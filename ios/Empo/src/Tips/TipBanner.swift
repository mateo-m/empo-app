import SwiftUI


struct TipBanner: View {
    let tip: Tip
    @Environment(\.tipStore) private var store

    @State private var showDetail = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "lightbulb.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)

            Text(tip.excerpt)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tip.hasDetail {
                Button("More") { showDetail = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.brand)
            }

            if tip.isDismissable {
                Button {
                    withAnimation(Motion.standard) {
                        store.dismiss(tip)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.brand.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss tip")
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(Color.brand.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .sheet(isPresented: $showDetail) {
            if let description = tip.description {
                TipDetailSheet(excerpt: tip.excerpt, description: description)
            }
        }
    }
}


private struct TipDetailSheet: View {
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
            .navigationTitle("Tip")
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
