// ============================================================
// CameraPicker - wrapper SwiftUI sobre UIImagePickerController
// para abrir la cámara del dispositivo y obtener una foto.
// ============================================================

import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    /// Tipo de fuente: cámara trasera por defecto.
    var sourceType: UIImagePickerController.SourceType = .camera
    /// Se llama al terminar la captura con la imagen resultante.
    var onImage: (UIImage) -> Void
    /// Se llama si el usuario cancela.
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.cameraDevice = .rear
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // Nada que actualizar; la cámara se configura al crearse.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
            picker.dismiss(animated: true)
        }
    }
}