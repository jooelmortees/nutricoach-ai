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
        case .fileTooLarge: return "El archivo es demasiado pesado."
        }
    }
}

@MainActor
final class StorageService {
    static let shared = StorageService()

    private let supabase = SupabaseService.shared.client

    private init() {}

    private let chatBucket = "chat-attachments"
    private let maxChatAttachmentBytes = 8 * 1024 * 1024

    func uploadChatImage(data: Data, conversationId: String) async throws -> MessageAttachment {
        guard data.count <= maxChatAttachmentBytes else { throw StorageError.fileTooLarge }
        let userId = try await supabase.auth.session.user.id.uuidString.lowercased()
        let attachmentId = UUID()
        let name = "imagen-\(attachmentId.uuidString.prefix(8)).jpg"
        let path = "\(userId)/\(conversationId.lowercased())/\(attachmentId.uuidString.lowercased()).jpg"

        do {
            try await supabase.storage
                .from(chatBucket)
                .upload(
                    path,
                    data: data,
                    options: FileOptions(contentType: "image/jpeg", upsert: false)
                )
        } catch {
            throw StorageError.uploadFailed(error.localizedDescription)
        }

        do {
            let signedURL = try await supabase.storage
                .from(chatBucket)
                .createSignedURL(path: path, expiresIn: 3600)
            return MessageAttachment(
                id: attachmentId,
                type: "image",
                bucket: chatBucket,
                path: path,
                url: signedURL.absoluteString,
                mimeType: "image/jpeg",
                name: name,
                sizeBytes: data.count
            )
        } catch {
            try? await supabase.storage.from(chatBucket).remove(paths: [path])
            throw StorageError.signedUrlFailed(error.localizedDescription)
        }
    }

    func uploadChatAudio(_ recording: RecordedAudio, conversationId: String) async throws -> MessageAttachment {
        guard recording.sizeBytes <= maxChatAttachmentBytes else { throw StorageError.fileTooLarge }
        let userId = try await supabase.auth.session.user.id.uuidString.lowercased()
        let name = "grabacion-\(recording.id.uuidString.prefix(8)).wav"
        let path = "\(userId)/\(conversationId.lowercased())/\(recording.id.uuidString.lowercased()).wav"

        do {
            try await supabase.storage
                .from(chatBucket)
                .upload(
                    path,
                    fileURL: recording.fileURL,
                    options: FileOptions(contentType: "audio/wav", upsert: false)
                )
        } catch {
            throw StorageError.uploadFailed(error.localizedDescription)
        }

        do {
            let signedURL = try await supabase.storage
                .from(chatBucket)
                .createSignedURL(path: path, expiresIn: 3600)
            return MessageAttachment(
                id: recording.id,
                type: "audio",
                bucket: chatBucket,
                path: path,
                url: signedURL.absoluteString,
                mimeType: "audio/wav",
                name: name,
                sizeBytes: recording.sizeBytes,
                durationSeconds: recording.duration
            )
        } catch {
            try? await supabase.storage.from(chatBucket).remove(paths: [path])
            throw StorageError.signedUrlFailed(error.localizedDescription)
        }
    }

    func refreshAccessURLs(in attachments: [MessageAttachment]) async -> [MessageAttachment] {
        var refreshed: [MessageAttachment] = []
        refreshed.reserveCapacity(attachments.count)

        for var attachment in attachments {
            if let bucket = attachment.bucket, let path = attachment.path {
                do {
                    let signedURL = try await supabase.storage
                        .from(bucket)
                        .createSignedURL(path: path, expiresIn: 3600)
                    attachment.url = signedURL.absoluteString
                } catch {
                    AppLogger.warning("No se pudo renovar un adjunto del chat: \(error.localizedDescription)")
                }
            } else if attachment.type == "image",
                      let legacyURL = attachment.url,
                      let path = storagePath(in: legacyURL, bucket: "meal-photos") {
                do {
                    let signedURL = try await supabase.storage
                        .from("meal-photos")
                        .createSignedURL(path: path, expiresIn: 3600)
                    attachment.url = signedURL.absoluteString
                } catch {
                    AppLogger.warning("No se pudo renovar una imagen antigua: \(error.localizedDescription)")
                }
            }
            refreshed.append(attachment)
        }
        return refreshed
    }

    func deleteChatAttachments(_ attachments: [MessageAttachment]) async {
        let paths = attachments.compactMap { attachment in
            attachment.bucket == chatBucket ? attachment.path : nil
        }
        guard !paths.isEmpty else { return }
        do {
            try await supabase.storage.from(chatBucket).remove(paths: paths)
        } catch {
            AppLogger.warning("No se pudieron limpiar adjuntos parciales: \(error.localizedDescription)")
        }
    }

    private func storagePath(in signedURL: String, bucket: String) -> String? {
        guard let range = signedURL.range(of: "/\(bucket)/") else { return nil }
        var path = String(signedURL[range.upperBound...])
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[..<queryStart])
        }
        return path.removingPercentEncoding ?? path
    }

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
