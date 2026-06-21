// ============================================================
// ChatViewModel - lógica del chat
// ============================================================

import Foundation
import SwiftUI
import PhotosUI
import Supabase
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isAgentThinking: Bool = false
    @Published var currentConversationId: String?
    @Published var errorMessage: String?
    /// Lista de imagenes pendientes de enviar (aun no subidas a Storage).
    @Published var pendingAttachments: [PendingAttachment] = []

    private let agent = AgentService.shared

    func loadOrCreateConversation() async {
        do {
            if currentConversationId == nil {
                let id = try await agent.loadOrCreateLatestConversation()
                currentConversationId = id
            }
            if let convId = currentConversationId {
                let history = try await agent.loadHistory(conversationId: convId)
                messages = history.map { h in
                    ChatMessage(
                        id: UUID(uuidString: h.id) ?? UUID(),
                        role: h.role,
                        content: h.content,
                        thinking: h.thinking,
                        attachments: h.attachments,
                        isStreaming: false
                    )
                }
            }
        } catch {
            errorMessage = "No se pudo cargar historial: \(error.localizedDescription)"
        }
    }

    func newConversation() async {
        do {
            let id = try await agent.createConversation()
            currentConversationId = id
            messages = []
            errorMessage = nil
            pendingAttachments = []
        } catch {
            errorMessage = "No se pudo crear conversación: \(error.localizedDescription)"
        }
    }

    /// Quita una imagen pendiente por su id (boton X del preview).
    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Limpia todas las imagenes pendientes.
    func clearPendingAttachments() {
        pendingAttachments = []
    }

    /// Envía un mensaje al agente. Sube TODAS las imagenes pendientes a Storage,
    /// las adjunta al mensaje, y limpia el estado de preview.
    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        guard hasText || hasAttachments else { return }
        guard let convId = currentConversationId else {
            errorMessage = "No hay conversación activa."
            return
        }

        // 1. Subir TODAS las imagenes pendientes y construir URLs firmadas
        var displayAttachments: [MessageAttachment] = []
        var agentAttachments: [AgentAttachment] = []
        var displayText = trimmed
        if hasAttachments && !hasText {
            displayText = "¿Qué macros tiene esta comida?"
        }
        // Snapshot para evitar race conditions si el user modifica el array
        let toUpload = pendingAttachments
        for attachment in toUpload {
            do {
                let url = try await StorageService.shared.uploadMealImage(data: attachment.imageData)
                displayAttachments.append(MessageAttachment(type: "image", url: url))
                agentAttachments.append(AgentAttachment(type: "image", url: url))
            } catch {
                errorMessage = "Error con la imagen: \(error.localizedDescription)"
                return
            }
        }

        // 2. Limpiar adjuntos pendientes (la UI ya no muestra preview)
        pendingAttachments = []

        // 3. Añadir mensaje del usuario a la UI (con attachments para mostrar)
        let userMsg = ChatMessage(
            role: .user,
            content: displayText,
            attachments: displayAttachments
        )
        messages.append(userMsg)
        isAgentThinking = true
        errorMessage = nil

        // 4. Crear placeholder del asistente
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        // 5. Enviar al agente
        await agent.sendMessage(
            conversationId: convId,
            message: displayText,
            attachments: agentAttachments
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.handle(event: event)
            }
        }

        // 6. Borrar imagenes de Storage tras enviar (1h de expiracion del signed URL
        //    deberia ser suficiente para que el cliente las muestre).
        //    NOTA: NO borramos hasta que el user salga del chat, para que
        //    los thumbnails sigan visibles todo el rato.
    }

    private func handle(event: AgentEvent) {
        switch event {
        case .thinkingDelta(let text):
            if let idx = messages.indices.last {
                messages[idx].thinking = (messages[idx].thinking ?? "") + text
            }
        case .textDelta(let text):
            if let idx = messages.indices.last {
                messages[idx].content += text
            }
        case .blockStart, .blockStop:
            break
        case .done:
            if let idx = messages.indices.last {
                messages[idx].isStreaming = false
            }
            isAgentThinking = false
        case .mealSaved(let kcal, let protein, let carbs, let fat, let description):
            let summary = formatMealSummary(kcal: kcal, protein: protein, carbs: carbs, fat: fat)
            messages.append(ChatMessage(
                role: .assistant,
                content: "🍽️ \(description)\n\(summary)\n\nRegistrada en tu pestaña Macros."
            ))
        case .error(let msg):
            errorMessage = msg
            isAgentThinking = false
            if let idx = messages.indices.last, messages[idx].role == .assistant && messages[idx].isStreaming {
                messages[idx].isStreaming = false
                if messages[idx].content.isEmpty {
                    messages[idx].content = "⚠️ \(msg)"
                }
            }
        }
    }

    /// El usuario seleccionó N imagenes del PhotosPicker. Las añadimos al
    /// preview sin subirlas todavia (se subiran al enviar).
    func handlePickedImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let compressed = compressImage(data: data, maxBytes: 2 * 1024 * 1024)
                guard let previewImage = UIImage(data: compressed) else { continue }
                let attachment = PendingAttachment(imageData: compressed, preview: previewImage)
                pendingAttachments.append(attachment)
            } catch {
                AppLogger.warning("No se pudo cargar imagen: \(error.localizedDescription)")
            }
        }
    }

    /// Guarda una comida (parseada del JSON de M3) en la tabla `meals` del usuario.
    /// Usado por el boton "Guardar en mi dia" que aparece cuando M3 devuelve
    /// macros en formato JSON.
    func saveMeal(_ meal: PendingMeal) async {
        guard let userId = currentConversationId ?? (try? await SupabaseService.shared.client.auth.session.user.id.uuidString) else {
            errorMessage = "No se pudo identificar al usuario"
            return
        }
        // Si tenemos currentConversationId, el user esta autenticado
        let actualUserId: String
        if let _ = currentConversationId {
            // Necesitamos el user ID del cliente Supabase
            do {
                actualUserId = try await SupabaseService.shared.client.auth.session.user.id.uuidString
            } catch {
                errorMessage = "Error de sesión"
                return
            }
        } else {
            actualUserId = userId
        }
        _ = actualUserId  // suppress unused warning, used in struct

        // Insertar en meals via Supabase
        struct InsertPayload: Encodable {
            let user_id: String
            let description: String
            let meal_type: String?
            let kcal: Double?
            let protein_g: Double?
            let carbs_g: Double?
            let fat_g: Double?
            let confidence: Double?
            let source: String
        }
        let payload = InsertPayload(
            user_id: actualUserId,
            description: meal.description,
            meal_type: meal.meal_type,
            kcal: meal.kcal,
            protein_g: meal.protein_g,
            carbs_g: meal.carbs_g,
            fat_g: meal.fat_g,
            confidence: meal.confidence,
            source: "text"
        )

        do {
            try await SupabaseService.shared.client
                .from("meals")
                .insert(payload)
                .execute()
            // Mensaje de confirmacion en el chat
            messages.append(ChatMessage(
                role: .assistant,
                content: "✅ Guardado: **\(meal.description)** en tu registro de comidas del día."
            ))
        } catch {
            errorMessage = "Error guardando comida: \(error.localizedDescription)"
        }
    }

    private func formatMealSummary(kcal: Double?, protein: Double?, carbs: Double?, fat: Double?) -> String {
        var parts: [String] = []
        if let kcal = kcal { parts.append("\(Int(kcal)) kcal") }
        if let p = protein { parts.append("P \(Int(p))g") }
        if let c = carbs { parts.append("C \(Int(c))g") }
        if let f = fat { parts.append("G \(Int(f))g") }
        return parts.joined(separator: " · ")
    }

    /// Comprime una imagen JPEG hasta maxBytes.
    private func compressImage(data: Data, maxBytes: Int) -> Data {
        guard let image = UIImage(data: data) else { return data }
        var quality: CGFloat = 0.8
        var result = data
        while result.count > maxBytes && quality > 0.1 {
            if let jpeg = image.jpegData(compressionQuality: quality) {
                result = jpeg
            }
            quality -= 0.1
        }
        return result
    }
}

/// Imagen pendiente (aún no enviada). Equivalente a un item del PhotosPicker
/// que se ha cargado pero no se ha subido a Storage todavía.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let imageData: Data
    let preview: UIImage

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// Attachment ya enviado (con URL firmada para mostrar en el chat).
struct MessageAttachment: Identifiable, Equatable, Codable {
    let id = UUID()
    let type: String  // "image" | "video"
    let url: String

    enum CodingKeys: String, CodingKey {
        case id, type, url
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var thinking: String?
    var attachments: [MessageAttachment]?
    var isStreaming: Bool = false

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        thinking: String? = nil,
        attachments: [MessageAttachment]? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.attachments = attachments
        self.isStreaming = isStreaming
    }

    enum Role {
        case user, assistant
    }
}