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

    /// Envía un mensaje al agente. Si hay un attachment pendiente (imagen local
    /// seleccionada por el usuario), primero la sube a Storage y luego la adjunta.
    /// Flujo:
    /// 1. Si hay pendingAttachment, subir a Storage (con feedback en el placeholder)
    /// 2. Construir AgentAttachment y enviar al agente con el texto
    /// 3. Limpiar pendingAttachment
    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasAttachment = pendingAttachment != nil
        guard hasText || hasAttachment else { return }
        guard let convId = currentConversationId else {
            errorMessage = "No hay conversación activa. Espera a que se cargue o crea una nueva."
            return
        }

        // 1. Si hay imagen pendiente, subirla y obtener URL firmada
        var attachments: [AgentAttachment] = []
        var displayText = trimmed
        if let attachment = pendingAttachment {
            // Si el usuario no escribió texto, usar uno por defecto
            if !hasText {
                displayText = "¿Qué macros tiene esta comida?"
            }
            do {
                let url = try await StorageService.shared.uploadMealImage(data: attachment.imageData)
                AppLogger.info("Imagen subida: \(url)")
                attachments.append(AgentAttachment(type: "image", url: url))
            } catch {
                errorMessage = "Error con la imagen: \(error.localizedDescription)"
                return
            }
        }

        // 2. Limpiar attachment pendiente ANTES de enviar para que la UI
        //    ya no muestre el preview (la imagen ahora viaja al backend)
        pendingAttachment = nil

        // 3. Añadir mensaje del usuario a la UI
        let userMsg = ChatMessage(role: .user, content: displayText)
        messages.append(userMsg)
        isAgentThinking = true
        errorMessage = nil

        // 4. Crear placeholder del asistente (se va rellenando con SSE)
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        // 5. Enviar al agente
        await agent.sendMessage(
            conversationId: convId,
            message: displayText,
            attachments: attachments
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.handle(event: event)
            }
        }

        // 6. Borrar imagen de Storage (no la necesitamos, solo el análisis textual)
        if let url = attachments.first?.url {
            await StorageService.shared.deleteMealImage(at: url)
        }
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
    /// Si el usuario ya tenía otra imagen pendiente, la reemplaza.
    func handlePickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "No se pudo cargar la imagen"
                return
            }
            // Comprimir a JPEG max 2MB
            let compressed = compressImage(data: data, maxBytes: 2 * 1024 * 1024)
            // Crear preview thumbnail para mostrar en la UI
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

/// Imagen seleccionada por el usuario que aún no se ha enviado.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let imageData: Data
    let preview: UIImage

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var thinking: String?
    var isStreaming: Bool = false

    init(id: UUID = UUID(), role: Role, content: String, thinking: String? = nil, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.isStreaming = isStreaming
    }

    enum Role {
        case user, assistant
    }
}