// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// Shows nothing for a row that the user did not change.
struct RemoveOverrideButton: View {
    let row: BindingsCatalog.Row
    let provenance: BindingsCatalog.Provenance?
    let scope: BindingsCatalog.Scope
    @Binding var refusal: UserControlsFile.SaveRefusal?

    var body: some View {
        if provenance == .userOverride {
            Button("Reset to default", role: .destructive) {
                do throws(UserControlsFile.SaveRefusal) {
                    try BindingsCatalog.removeOverride(source: row.source, scope: scope)
                } catch {
                    refusal = error
                }
            }
        }
    }
}

extension View {
    func resetBindingsAlert(
        isPresented: Binding<Bool>,
        scope: BindingsCatalog.Scope,
        gameTitle: String?,
        refusal: Binding<UserControlsFile.SaveRefusal?>
    ) -> some View {
        alert(BindingsCatalog.resetTitle(scope: scope), isPresented: isPresented) {
            Button("Reset", role: .destructive) {
                do throws(UserControlsFile.SaveRefusal) {
                    try scope.deleteOverrides()
                } catch {
                    refusal.wrappedValue = error
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BindingsCatalog.resetMessage(scope: scope, gameTitle: gameTitle))
        }
    }

    func bindingsSaveRefusalAlert(_ refusal: Binding<UserControlsFile.SaveRefusal?>) -> some View {
        alert(
            Text(BindingsCatalog.refusalMessage(refusal.wrappedValue ?? .fileHasErrors)),
            isPresented: Binding(
                get: { refusal.wrappedValue != nil },
                set: { if !$0 { refusal.wrappedValue = nil } })
        ) {
            Button("Got it") {}
        }
    }
}
