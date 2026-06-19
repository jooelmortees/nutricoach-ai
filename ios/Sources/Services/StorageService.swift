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
    /// válida por 1 hora. El nombre del archivo es único por timestamp+UUID.
    func uploadMealImage(data: Data) async throws -> String {
        guard data.count < 10 * 1024 * 1024 else {
            throw StorageError.fileTooLarge
        }

        let userId = try await supabase.auth.session.user.id
        let fileId = UUID().uuidString.prefix(8)
        let path = "\(userId.uuidString)/meal-\(Int(Date().timeIntervalSince1970))-\(fileId).jpg"

        // 1. Subir
        do {
            try await supabase.storage
                .from("meal-photos")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(contentType: "image/jpeg", upsert: false)
                )
        } catch {
            throw StorageError.uploadFailed(error.localizedDescription)
        }

        // 2. URL firmada (bucket privado)
        do {
            let signed = try await supabase.storage
                .from("meal-photos")
                .createSignedURL(path: path, expiresIn: 3600)
            return signed.signedURL.absoluteString
        } catch {
            throw StorageError.signedUrlFailed(error.localizedDescription)
        }
    }
}