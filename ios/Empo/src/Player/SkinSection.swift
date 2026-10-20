import GameProbe
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The profile editor's skin sheet: art per orientation and the
/// outlines switch. Everything writes straight to the profile folder.
///
/// The sheet owns the ONE photo picker and the ONE file importer and
/// remembers which orientation asked. SwiftUI presents only one of
/// several sibling `.fileImporter`s, so each section cannot carry its
/// own.
struct SkinSheet: View {
    let profileName: String
    /// Called after any change, so the editor canvas redraws.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showOutlines = false
    @State private var target: SkinOrientation = .portrait
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showError = false
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            Form {
                ForEach([SkinOrientation.portrait, .landscape], id: \.self) { orientation in
                    SkinSection(
                        profileName: profileName, orientation: orientation, revision: revision,
                        onAddFromPhotos: {
                            target = orientation
                            showPhotoPicker = true
                        },
                        onAddFromFiles: {
                            target = orientation
                            showFileImporter = true
                        },
                        onRemove: { remove(orientation) })
                }
                Section {
                    Toggle(
                        "Show button outlines",
                        isOn: Binding(get: { showOutlines }, set: saveOutlines))
                } footer: {
                    Text(
                        "Off: the art's painted buttons are the buttons, and Empo's controls only take touches. Edit mode always shows them."
                    )
                }
            }
            .navigationTitle("Skin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            let orientation = target
            Task { await importPhoto(item, into: orientation) }
        }
        .fileImporter(
            isPresented: $showFileImporter, allowedContentTypes: [.png, .jpeg, .image]
        ) { result in
            if case .success(let url) = result {
                importFile(url, into: target)
            }
        }
        .alert("Couldn't use that image", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The skin art is unchanged. Try a PNG or JPEG image.")
        }
        .onAppear {
            showOutlines =
                LayoutProfilesManager.skinSettings(profile: profileName).showButtonOutlines
        }
    }

    /// Writes only real changes, and keeps the toggle on what is on
    /// disk when the write fails.
    private func saveOutlines(_ value: Bool) {
        guard value != showOutlines else { return }
        let folder = LayoutProfilesManager.store.profileURL(profileName)
        do {
            try SkinFiles.writeSettings(
                SkinSettings(showButtonOutlines: value), profileFolder: folder)
        } catch {
            showError = true
            return
        }
        showOutlines = value
        changed()
    }

    private func importPhoto(_ item: PhotosPickerItem, into orientation: SkinOrientation) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            showError = true
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension
        install(data, fileExtension: ext, into: orientation)
    }

    private func importFile(_ url: URL, into orientation: SkinOrientation) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else {
            showError = true
            return
        }
        install(data, fileExtension: url.pathExtension, into: orientation)
    }

    /// PNG and JPEG keep their bytes. Anything else that decodes (HEIC
    /// from Photos, for example) is re-encoded as JPEG.
    private func install(_ data: Data, fileExtension: String?, into orientation: SkinOrientation) {
        guard let decoded = UIImage(data: data) else {
            showError = true
            return
        }
        let ext = fileExtension?.lowercased() ?? ""
        let folder = LayoutProfilesManager.store.profileURL(profileName)
        do {
            if SkinFiles.extensions.contains(ext) {
                try SkinFiles.installArt(
                    data, fileExtension: ext, orientation: orientation, profileFolder: folder)
            } else if let jpeg = decoded.jpegData(compressionQuality: 0.9) {
                try SkinFiles.installArt(
                    jpeg, fileExtension: "jpg", orientation: orientation, profileFolder: folder)
            } else {
                showError = true
                return
            }
        } catch {
            showError = true
            return
        }
        changed()
    }

    private func remove(_ orientation: SkinOrientation) {
        let folder = LayoutProfilesManager.store.profileURL(profileName)
        do {
            try SkinFiles.removeArt(orientation: orientation, profileFolder: folder)
        } catch {
            showError = true
            return
        }
        changed()
    }

    /// The posted change clears the art cache and redraws the player,
    /// the lists, and (through `onChange`) the editor canvas.
    private func changed() {
        LayoutProfilesManager.postProfileChange(name: profileName, from: nil)
        revision += 1
        onChange()
    }
}

/// One orientation's art: a preview plus add, replace, and remove.
/// Presentation of the pickers belongs to `SkinSheet`.
struct SkinSection: View {
    let profileName: String
    let orientation: SkinOrientation
    /// Bumped by the sheet after a change, so the preview re-reads.
    let revision: Int
    let onAddFromPhotos: () -> Void
    let onAddFromFiles: () -> Void
    let onRemove: () -> Void

    private var title: String {
        orientation == .portrait ? "Portrait art" : "Landscape art"
    }

    var body: some View {
        let art = LayoutProfilesManager.skinArt(
            profile: profileName, orientation: orientation, maxPixel: 400)
        Section(title) {
            if let art {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            Menu(art == nil ? "Add image" : "Replace image") {
                Button(action: onAddFromPhotos) {
                    Label("Photos", systemImage: "photo")
                }
                Button(action: onAddFromFiles) {
                    Label("Files", systemImage: "folder")
                }
            }
            if art != nil {
                Button("Remove image", role: .destructive, action: onRemove)
            }
        }
        .id(revision)
    }
}

/// A small art preview for the profile lists. Portrait art first,
/// landscape as the fallback, nothing without art. Re-reads on any
/// profile change, since the lists do not rebuild their rows.
struct SkinThumbnail: View {
    let profileName: String

    @State private var revision = 0

    var body: some View {
        let image =
            LayoutProfilesManager.skinArt(
                profile: profileName, orientation: .portrait, maxPixel: 132)
            ?? LayoutProfilesManager.skinArt(
                profile: profileName, orientation: .landscape, maxPixel: 132)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
        }
        .id(revision)
        .onReceive(NotificationCenter.default.publisher(for: .layoutProfileDidChange)) { _ in
            revision += 1
        }
    }
}
