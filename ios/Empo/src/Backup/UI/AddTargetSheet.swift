import GameProbe
import SwiftUI

/// The service list of SPEC 13.7.
///
/// It names services and the user's own labels, and it never says
/// "provider". The iCloud entry follows the runtime gate of 9.1:
/// hidden while the probe answers nil, greyed when the build cannot
/// open it.
struct AddTargetSheet: View {

    let iCloudReach: TargetReach
    let added: (TargetDescriptor, PermissionCheckResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typing: BackupProviderKind?
    @State private var isWorking = false
    @State private var failure: String?

    private var services: [BackupProviderKind] {
        BackupTargetAdd.offeredServices(iCloudReach: iCloudReach)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(services, id: \.self) { service in
                        Button(service.serviceName) { start(service) }
                            .disabled(isGreyed(service))
                    }
                } footer: {
                    if isGreyed(.iCloudDrive) {
                        Text("This build cannot open iCloud Drive.")
                    }
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add a target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isWorking { ProgressView() }
            }
            .navigationDestination(item: $typing) { service in
                TargetFormScreen(service: service) { values in
                    Task { await finish(await add(service, values: values)) }
                }
            }
        }
    }

    private func isGreyed(_ service: BackupProviderKind) -> Bool {
        service == .iCloudDrive && iCloudReach == .notInThisBuild
    }

    private func start(_ service: BackupProviderKind) {
        switch service {
        case .s3, .webdav, .sftp:
            typing = service
        case .iCloudDrive, .dropbox, .googleDrive:
            Task { await finish(await add(service, values: [:])) }
        }
    }

    private func add(
        _ service: BackupProviderKind, values: [String: String]
    ) async -> BackupTargetAdd.Outcome {
        isWorking = true
        defer { isWorking = false }
        switch service {
        case .iCloudDrive:
            return await BackupTargetAdd.iCloud()
        case .dropbox, .googleDrive:
            guard let screen = await OAuthSignIn.screenForTheSheet() else {
                return .failed("Empo found no screen to sign in from.")
            }
            return service == .dropbox
                ? await BackupTargetAdd.dropbox(presenting: screen)
                : await BackupTargetAdd.googleDrive(presenting: screen)
        case .s3:
            return await BackupTargetAdd.s3(form: values)
        case .webdav:
            return await BackupTargetAdd.webdav(form: values)
        case .sftp:
            // `offeredServices` draws no SFTP row, so nothing
            // reaches this. The kind stays for the format of 5.
            return .failed("Empo has no SFTP target.")
        }
    }

    private func finish(_ outcome: BackupTargetAdd.Outcome) async {
        switch outcome {
        case .checked(let descriptor, let result):
            added(descriptor, result)
            dismiss()
        case .cancelled:
            failure = nil
        case .failed(let line):
            failure = line
        }
    }
}

/// The add form of SPEC 13.7. Each provider states its own fields,
/// and the host field carries the storage warning of 5.7.
struct TargetFormScreen: View {

    let service: BackupProviderKind
    let submit: ([String: String]) -> Void

    @State private var values: [String: String] = [:]

    private var fields: [TargetFormField] {
        switch service {
        case .s3: return S3.addFormFields
        case .webdav: return WebDAV.addFormFields
        default: return []
        }
    }

    private var isComplete: Bool {
        fields.filter(\.isRequired).allSatisfy { !(values[$0.name] ?? "").isEmpty }
    }

    var body: some View {
        Form {
            ForEach(fields, id: \.name) { field in
                Section {
                    input(field)
                } footer: {
                    if let note = field.note { Text(note) }
                }
            }
            Section {
                Button("Add") { submit(values) }
                    .disabled(!isComplete)
            }
        }
        .navigationTitle(service.serviceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func input(_ field: TargetFormField) -> some View {
        let text = Binding(
            get: { values[field.name] ?? "" },
            set: { values[field.name] = $0 })
        switch field.kind {
        case .text:
            TextField(field.label, text: text, prompt: Text(field.hint))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .secret:
            SecureField(field.label, text: text, prompt: Text(field.hint))
        case .toggle:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { values[field.name] == "true" },
                    set: { values[field.name] = $0 ? "true" : "false" }))
        }
    }
}
