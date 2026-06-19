// ============================================================
// StorageService - subida de archivos a Supabase Storage
// ============================================================

import Foundation
import Supabase

enum StorageError: LocalizedError {
    case uploadFailed(String)
    case signedUrlFailed(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let m): return "Error subiendo archivo: \(m)"
        case .signedUrlFailed(let m): return "Error generando URL firmada: \(m)"
        case .fileTooLarge: return "La imagen es demasiado pesada (máx 10 MB)"
        }
    }
}

@MainActor
final class StorageService {
    static let shared = StorageService()

    private let supabase = SupabaseService.shared.client

    private init() {}

    /// Sube una imagen al bucket privado `meal-photos` y devuelve una URL firmada
    /// válida por 1 hora. El path incluye el UUID del usuario como primer segmento,
    /// lo cual cumple la RLS policy `meal_photos_insert_own`.
    func uploadMealImage(data: Data) async throws -> String {
        guard data.count < 10 * 1024 * 1024 else {
            throw StorageError.fileTooLarge
        }

        let userId = try await supabase.auth.session.user.id
        let fileId = UUID().uuidString.prefix(8)
        let path = "\(userId.uuidString)/meal-\(Int(Date().timeIntervalSince1970))-\(fileId).jpg"
        AppLogger.info("Subiendo imagen a path: \(path)")

        // 1. Subir
        do {
            try await supabase.storage
                .from("meal-photos")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(contentType: "image/jpeg", upsert: false)
                )
            AppLogger.info("Imagen subida OK: \(path)")
        } catch {
            AppLogger.error("Upload fallo: \(error.localizedDescription) | path=\(path) | userId=\(userId.uuidString)")
            throw StorageError.uploadFailed(error.localizedDescription)
        }

        // 2. URL firmada (bucket privado, válida 1h)
        do {
            let signed = try await supabase.storage
                .from("meal-photos")
                .createSignedURL(path: path, expiresIn: 3600)
            return signed.absoluteString
        } catch {
            AppLogger.error("Signed URL fallo: \(error.localizedDescription)")
            throw StorageError.signedUrlFailed(error.localizedDescription)
        }
    }

    /// Borra una imagen del bucket a partir de su URL firmada.
    func deleteMealImage(at url: String) async {
        // Extraemos el path del URL (después del bucket, quitando query string)
        guard let range = url.range(of: "/meal-photos/") else { return }
        let pathStart = url.index(range.upperBound, offsetBy: 0)
        var path = String(url[pathStart...])
        if let queryRange = path.range(of: "?") {
            path = String(path[..<queryRange.lowerBound])
        }
        do {
            try await supabase.storage.from("meal-photos").remove(paths: [path])
            AppLogger.info("Imagen borrada: \(path)")
        } catch {
            AppLogger.warning("No se pudo borrar imagen: \(error.localizedDescription)")
        }
    }
}