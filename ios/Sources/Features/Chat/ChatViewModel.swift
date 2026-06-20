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
    @Published var pendingAttachment: PendingAttachment?

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
            pendingAttachment = nil
        } catch {
            errorMessage = "No se pudo crear conversación: \(error.localizedDescription)"
        }
    }

    func cancelPendingAttachment() {
        pendingAttachment = nil
    }

    /// Envía un mensaje al agente. Si hay un attachment pendiente, primero
    /// lo sube a Storage para obtener una URL firmada que se pasa al modelo.
    /// Flujo:
    /// 1. Subir imagen a Storage
    /// 2. Crear AgentAttachment con URL firmada
    /// 3. Construir mensaje con texto + adjuntos
    /// 4. Añadir mensaje a la UI (con el attachment URL para mostrar thumbnail)
    /// 5. Enviar al agente via SSE
    /// 6. NO borrar la imagen: se mantiene en Storage 1h para que el modelo
    ///    la pueda descargar, y porque el usuario quiere ver su propia foto
    ///    enviada en el chat. Se borra automaticamente al expirar el signed URL.
    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasAttachment = pendingAttachment != nil
        guard hasText || hasAttachment else { return }
        guard let convId = currentConversationId else {
            errorMessage = "No hay conversación activa. Espera a que se cargue o crea una nueva."
            return
        }

        // 1. Si hay imagen pendiente, subirla a Storage
        var displayAttachments: [MessageAttachment] = []
        var agentAttachments: [AgentAttachment] = []
        var displayText = trimmed
        if let attachment = pendingAttachment {
            // Si el usuario no escribió texto, usar uno por defecto
            if !hasText {
                displayText = "¿Qué macros tiene esta comida?"
            }
            do {
                let url = try await StorageService.shared.uploadMealImage(data: attachment.imageData)
                AppLogger.info("Imagen subida: \(url)")
                let messageAtt = MessageAttachment(type: "image", url: url)
                displayAttachments.append(messageAtt)
                agentAttachments.append(AgentAttachment(type: "image", url: url))
            } catch {
                errorMessage = "Error con la imagen: \(error.localizedDescription)"
                return
            }
        }

        // 2. Limpiar attachment pendiente
        pendingAttachment = nil

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

        // NOTA: NO borramos la imagen de Storage. Razones:
        // 1. El usuario quiere ver su foto enviada en el chat (thumbnail)
        // 2. La URL firmada expira en 1h, asi que no hay coste permanente
        // 3. Si el modelo no soporta vision, queda como evidencia visual
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
                    messages[idx].content = "⚠️ Error: \(msg)"
                }
            }
        }
    }

    /// El usuario seleccionó una imagen del PhotosPicker. La guardamos en
    /// `pendingAttachment` (solo en memoria) para mostrar preview. NO la subimos
    /// todavía — esperamos a que el usuario pulse enviar.
    func handlePickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "No se pudo cargar la imagen"
                return
            }
            let compressed = compressImage(data: data, maxBytes: 2 * 1024 * 1024)
            guard let previewImage = UIImage(data: compressed) else {
                errorMessage = "No se pudo procesar la imagen"
                return
            }
            pendingAttachment = PendingAttachment(imageData: compressed, preview: previewImage)
            errorMessage = nil
        } catch {
            errorMessage = "Error con la imagen: \(error.localizedDescription)"
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

    /// Comprime una imagen JPEG hasta que esté por debajo de maxBytes.
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

/// Imagen pendiente (aún no enviada).
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