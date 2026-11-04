import GameProbe
import SwiftUI

/// The service list of SPEC 13.7.
///
/// The iCloud entry follows the runtime gate of 9.1: hidden while the
/// probe answers nil, greyed when the build cannot open it.
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
                    serviceRows(services.filter { !BackupTargetAdd.signsInThroughTheForm($0) })
                } header: {
                    Text("Accounts")
                } footer: {
                    Text(
                        isGreyed(.iCloudDrive)
                            ? "Sign in with an account you already have. This version of Empo can't use iCloud Drive."
                            : "Sign in with an account you already have.")
                }
                Section {
                    serviceRows(services.filter(BackupTargetAdd.signsInThroughTheForm))
                } header: {
                    Text("Servers and storage")
                } footer: {
                    Text("For storage you set up yourself. You need its address and sign-in details.")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add a location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isWorking { CheckingOverlay() }
            }
            .navigationDestination(item: $typing) { service in
                TargetFormScreen(service: service) { values in
                    service == .s3
                        ? await BackupTargetAdd.s3(form: values)
                        : await BackupTargetAdd.webdav(form: values)
                } done: { descriptor, result in
                    added(descriptor, result)
                    dismiss()
                }
            }
        }
    }

    private func serviceRows(_ services: [BackupProviderKind]) -> some View {
        ForEach(services, id: \.self) { service in
            Button {
                start(service)
            } label: {
                serviceRow(service)
            }
            // The sheet's brand tint would color the whole label.
            .tint(.primary)
            .disabled(isGreyed(service) || isWorking)
        }
    }

    private func serviceRow(_ service: BackupProviderKind) -> some View {
        HStack(spacing: Spacing.lg) {
            AccountAvatar(photo: nil, provider: service, size: 32)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(service.serviceName).foregroundStyle(.primary)
                if let examples = examples(of: service) {
                    Text(examples).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func examples(of service: BackupProviderKind) -> String? {
        switch service {
        case .s3: return "Amazon S3, Cloudflare R2, Backblaze B2, MinIO"
        case .webdav: return "Nextcloud, ownCloud, Synology, Koofr"
        case .iCloudDrive, .dropbox, .googleDrive, .sftp: return nil
        }
    }

    private func isGreyed(_ service: BackupProviderKind) -> Bool {
        service == .iCloudDrive && iCloudReach == .notInThisBuild
    }

    private func start(_ service: BackupProviderKind) {
        failure = nil
        switch service {
        case .s3, .webdav, .sftp:
            typing = service
        case .iCloudDrive, .dropbox, .googleDrive:
            Task { await signIn(service) }
        }
    }

    private func signIn(_ service: BackupProviderKind) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome: BackupTargetAdd.Outcome
        switch service {
        case .iCloudDrive:
            outcome = await BackupTargetAdd.iCloud()
        default:
            guard let screen = await OAuthSignIn.screenForTheSheet() else {
                failure = BackupTargetAdd.noSignInScreenLine
                return
            }
            outcome =
                service == .dropbox
                ? await BackupTargetAdd.dropbox(presenting: screen)
                : await BackupTargetAdd.googleDrive(presenting: screen)
        }
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

/// The add form of SPEC 13.7, and the sign-in form of 8.8 for the
/// services the user types.
///
/// A failed check keeps the form and what the user typed, and names
/// the cause above the button.
struct TargetFormScreen: View {

    let service: BackupProviderKind
    var values: [String: String] = [:]
    var lockedFields: Set<String> = []
    var submitTitle = "Add"
    let submit: ([String: String]) async -> BackupTargetAdd.Outcome
    let done: (TargetDescriptor, PermissionCheckResult) -> Void

    @State private var typed: [String: String] = [:]
    @State private var isWorking = false
    @State private var failure: String?
    @FocusState private var focused: String?

    private var fields: [TargetFormField] {
        switch service {
        case .s3: return S3.addFormFields
        case .webdav: return WebDAV.addFormFields
        default: return []
        }
    }

    private var groups: [String] {
        fields.map(\.group).reduce(into: []) { groups, group in
            if !groups.contains(group) { groups.append(group) }
        }
    }

    private var typingFields: [String] {
        fields.filter { $0.kind != .toggle && !lockedFields.contains($0.name) }.map(\.name)
    }

    private var isComplete: Bool {
        fields.filter(\.isRequired).allSatisfy { !(typed[$0.name] ?? "").isEmpty }
    }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                ForEach(groups, id: \.self) { group in
                    let groupFields = fields.filter { $0.group == group }
                    Section {
                        ForEach(groupFields, id: \.name) { field in
                            row(field)
                        }
                    } header: {
                        Text(group)
                    } footer: {
                        if groupFields.contains(where: { $0.name == "address" }),
                            let address = BackupTargetAdd.backupAddress(of: service, form: typed)
                        {
                            Text("Empo saves backups at \(Text(address).monospaced())")
                        }
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }
                    .id("failure")
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Text(isWorking ? "Checking…" : submitTitle)
                            if isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .accessibilityIdentifier("submitTarget")
                    .disabled(!isComplete || isWorking)
                } footer: {
                    Text(TransportSecurity.storageWarning)
                }
            }
            .disabled(isWorking)
            .onChange(of: failure) { _, failure in
                guard failure != nil else { return }
                withAnimation { scroll.scrollTo("failure", anchor: .center) }
                UIAccessibility.post(notification: .announcement, argument: failure)
            }
        }
        .onAppear { typed = values }
        .onChange(of: typed) { failure = nil }
        .navigationTitle(service.serviceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(submitTitle) { Task { await send() } }
                    .disabled(!isComplete || isWorking)
            }
        }
    }

    private func send() async {
        guard isComplete, !isWorking else { return }
        focused = nil
        isWorking = true
        defer { isWorking = false }
        switch await submit(typed) {
        case .checked(let descriptor, let result) where result.allowsAdd:
            done(descriptor, result)
        case .checked(_, let result):
            failure =
                result.failureLine(for: service) ?? "Empo couldn't check this location. Try again."
        case .cancelled:
            failure = nil
        case .failed(let line):
            failure = line
        }
    }

    @ViewBuilder private func row(_ field: TargetFormField) -> some View {
        let locked = lockedFields.contains(field.name)
        let note =
            locked ? "To change this, remove the location and add it again." : field.note
        if field.kind == .toggle {
            Toggle(isOn: toggle(field)) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(field.label)
                    if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .disabled(locked)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(field.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                input(field)
                    .focused($focused, equals: field.name)
                    .submitLabel(field.name == typingFields.last ? .done : .next)
                    .onSubmit { next(after: field.name) }
                    .disabled(locked)
                    // A disabled TextField in a Form keeps the primary text color.
                    .foregroundStyle(locked ? .secondary : .primary)
                    .accessibilityLabel(field.label)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private func next(after name: String) {
        guard let index = typingFields.firstIndex(of: name),
            index + 1 < typingFields.count
        else {
            Task { await send() }
            return
        }
        focused = typingFields[index + 1]
    }

    private func toggle(_ field: TargetFormField) -> Binding<Bool> {
        Binding(
            get: { BackupTargetAdd.isOn(field.name, in: typed) },
            set: { typed[field.name] = $0 ? "true" : "false" })
    }

    @ViewBuilder private func input(_ field: TargetFormField) -> some View {
        let text = Binding(
            get: { typed[field.name] ?? "" },
            set: { typed[field.name] = $0 })
        let prompt = field.hint.isEmpty ? nil : Text(field.hint)
        switch field.kind {
        case .text where field.name == "label":
            TextField(field.label, text: text, prompt: prompt)
                .textInputAutocapitalization(.words)
        case .text, .toggle:
            TextField(field.label, text: text, prompt: prompt)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Without a type, iOS takes the key ID beside a hidden
                // field for a user name and offers to save a password.
                .textContentType(field.name == "accessKeyId" ? .oneTimeCode : nil)
        case .address:
            TextField(field.label, text: text, prompt: prompt)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .userName:
            TextField(field.label, text: text, prompt: prompt)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .password:
            SecureField(field.label, text: text, prompt: prompt)
                .textContentType(.password)
        case .secret:
            SecureField(field.label, text: text, prompt: prompt)
                .textContentType(.oneTimeCode)
        }
    }
}

/// What the add sheet shows while a sign-in or a check runs.
struct CheckingOverlay: View {
    var body: some View {
        ProgressView("Checking the location…")
            .padding(Spacing.xl)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}
