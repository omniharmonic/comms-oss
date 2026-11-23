#if os(iOS)
import CommsCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the camera captured: a still (JPEG bytes, no location: re-encoded from the image) or
/// a movie (moved into ``OutgoingFiles``; the composer strips its location).
enum CameraCapture {
    case photo(Data)
    case movie(URL)
}

/// The system camera (photo or video), as Messages' "+ → Camera" opens it. Hands back the
/// capture, or nil when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (CameraCapture?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (CameraCapture?) -> Void
        init(done: @escaping (CameraCapture?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                let dest = OutgoingFiles.newURL(extension: url.pathExtension)
                if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { done(.movie(dest)) } else { done(nil) }
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                done(.photo(data))
            } else {
                done(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
#endif
