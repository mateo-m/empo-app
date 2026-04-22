import SwiftUI
import PhotosUI
import UniformTypeIdentifiers


struct ImageSourcePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let hasExisting: Bool
    let onImageSelected: (UIImage) -> Void
    let onRemove: (() -> Void)?

    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showDocumentPicker = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                ImageSourceSheet(
                    isPresented: $isPresented,
                    title: title,
                    hasExisting: hasExisting,
                    onPickPhoto: { showPhotoPicker = true },
                    onTakePhoto: { showCamera = true },
                    onPickFile: { showDocumentPicker = true },
                    onRemove: onRemove
                )
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker(onImageSelected: onImageSelected)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(onImageSelected: onImageSelected)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showDocumentPicker) {
                ImageDocumentPicker(onImageSelected: onImageSelected)
            }
    }
}

extension View {
    func imageSourcePicker(
        isPresented: Binding<Bool>,
        title: String = "Choose image",
        hasExisting: Bool = false,
        onImageSelected: @escaping (UIImage) -> Void,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        modifier(ImageSourcePickerModifier(
            isPresented: isPresented,
            title: title,
            hasExisting: hasExisting,
            onImageSelected: onImageSelected,
            onRemove: onRemove
        ))
    }
}


private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onImageSelected: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            provider.loadObject(ofClass: UIImage.self) { image, _ in
                if let image = image as? UIImage {
                    Task { @MainActor in
                        self.parent.onImageSelected(image)
                    }
                }
            }
        }
    }
}


private struct CameraPicker: UIViewControllerRepresentable {
    let onImageSelected: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                parent.onImageSelected(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}


private struct ImageDocumentPicker: UIViewControllerRepresentable {
    let onImageSelected: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ImageDocumentPicker
        init(_ parent: ImageDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                           didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                parent.onImageSelected(image)
            }
        }
    }
}
