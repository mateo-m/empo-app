// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// Shows nothing for a row that the user did not change.
struct RemoveOverrideButton: View {
    let row: BindingsCatalog.Row
    let provenance: BindingsCatalog.Provenance?
    let scope: BindingsCatalog.Scope

    var body: some View {
        if provenance == .userOverride {
            Button("Reset to default", role: .destructive) {
                BindingsCatalog.removeOverride(source: row.source, scope: scope)
            }
        }
    }
}

extension View {
    func resetBindingsAlert(
        isPresented: Binding<Bool>,
        scope: BindingsCatalog.Scope,
        gameTitle: String?
    ) -> some View {
        alert(BindingsCatalog.resetTitle(scope: scope), isPresented: isPresented) {
            Button("Reset", role: .destructive) {
                scope.deleteOverrides()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BindingsCatalog.resetMessage(scope: scope, gameTitle: gameTitle))
        }
    }
}
