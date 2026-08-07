import GameProbe
import SwiftUI

/// Key/action picker for controller remap rows (ticket 005 §4).
struct ControllerBindingPickerSheet: View {
    let elementLabel: String
    let current: ControllerMap.Target?
    let onSelect: (ControllerMap.Target) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    ForEach(EmpoActionCatalog.all, id: \.id) { action in
                        actionRow(
                            label: action.displayName,
                            blurb: action.blurb,
                            target: .action(action.id)
                        )
                    }
                    actionRow(label: "Unbound", target: .unbound)
                }

                ForEach(KeyCodePickerGroup.allCases, id: \.self) { group in
                    let codes = KeyCodeTable.codesByPickerGroup[group] ?? []
                    if !codes.isEmpty {
                        Section(KeyCodeTable.pickerGroupTitle(group)) {
                            ForEach(codes, id: \.self) { code in
                                keyRow(code: code, group: group)
                            }
                        }
                    }
                }
            }
            .navigationTitle(elementLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func actionRow(
        label: String,
        blurb: String? = nil,
        target: ControllerMap.Target
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let blurb {
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if targetsMatch(current, target) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.brand)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(target)
            dismiss()
        }
    }

    private func keyRow(code: String, group: KeyCodePickerGroup) -> some View {
        let target: ControllerMap.Target = .key(code)
        let title = KeyCodeTable.displayName(for: code) ?? code
        let annotation = group == .common ? ControllerRemapCatalog.commonKeyAnnotations[code] : nil

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let annotation {
                    Text(annotation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if targetsMatch(current, target) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.brand)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(target)
            dismiss()
        }
    }

    private func targetsMatch(_ lhs: ControllerMap.Target?, _ rhs: ControllerMap.Target) -> Bool {
        switch (lhs, rhs) {
        case (.key(let a), .key(let b)): return a == b
        case (.action(let a), .action(let b)): return a == b
        case (.unbound, .unbound): return true
        default: return false
        }
    }
}
