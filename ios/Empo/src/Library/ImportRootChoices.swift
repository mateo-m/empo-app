// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

extension ImportRootPrompt {
    var freshChoices: [GameImportValidator.ImportRootChoice] {
        choices.filter { !updatingChoiceIDs.contains($0.id) }
    }

    var updateChoices: [GameImportValidator.ImportRootChoice] {
        choices.filter { updatingChoiceIDs.contains($0.id) }
    }

    static func title(showingUpdates: Bool) -> LocalizedStringResource {
        showingUpdates
            ? "Importing replaces the games in your library"
            : "This import includes more than one game"
    }
}

struct ImportRootChoiceArtworkView: View {
    let artwork: ImportRootChoiceArtwork?

    var body: some View {
        ZStack {
            placeholderBackground
            renderedArtwork
        }
        .frame(width: AppSize.listArtwork, height: AppSize.listArtwork)
        .clipShape(.pixelRect(cornerRadius: Radius.sm))
    }

    @ViewBuilder
    private var renderedArtwork: some View {
        if let data = artwork?.imageData {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderIcon
            }
        } else if let data = artwork?.iconData {
            if let image = UIImage(data: data) {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.75, height: side * 0.75)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                placeholderIcon
            }
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(.empoMark)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(.quaternary)
    }

    private var placeholderBackground: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .controlBackgroundColor)
            #else
            Color(.secondarySystemBackground)
            #endif
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.05), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
