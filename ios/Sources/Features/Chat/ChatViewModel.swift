// ============================================================
// ChatViewModel - lógica del chat
// ============================================================

import Foundation
import SwiftUI
import PhotosUI
import Supabase

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isAgentThinking: Bool = false
    @Published var currentConversationId: String?
    @Published var errorMessage: String?
    @Published var pendingImageDescription: String?

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
        } catch {
            errorMessage = "No se pudo crear conversación: \(error.localizedDescription)"
        }
    }

    /// Envía un mensaje al agente. Soporta texto + adjuntos opcionales.
    /// Si hay una imagen pendiente, la sube a Storage y la incluye como attachment.
    func send(_ text: String, attachments: [AgentAttachment] = []) async {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let convId = currentConversationId else {
            errorMessage = "No hay conversación activa. Espera a que se cargue o crea una nueva."
            return
        }

        // 1. Añadir mensaje del usuario a la UI
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        isAgentThinking = true
        errorMessage = nil

        // 2. Crear placeholder del asistente (se va rellenando con SSE)
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        // 3. Enviar al agente
        await agent.sendMessage(
            conversationId: convId,
            message: text,
            attachments: attachments
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.handle(event: event)
            }
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
            // Mostrar confirmación visual de comida registrada
            let summary = formatMealSummary(kcal: kcal, protein: protein, carbs: carbs, fat: fat)
            messages.append(ChatMessage(
                role: .assistant,
                content: "🍽️ \(description)\n\(summary)\n\nRegistrada en tu pestaña Macros."
            ))
        case .error(let msg):
            errorMessage = msg
            isAgentThinking = false
            // Marcar el último mensaje como no-streaming para que no quede en streaming perpetuo
            if let idx = messages.indices.last, messages[idx].role == .assistant && messages[idx].isStreaming {
                messages[idx].isStreaming = false
                if messages[idx].content.isEmpty {
                    messages[idx].content = "⚠️ Error: \(msg)"
                }
            }
        }
    }

    /// Maneja una imagen seleccionada por el usuario: la sube a Storage, la envía
    /// al agente para análisis, y borra la imagen una vez analizada.
    /// El agente devuelve las macros estimadas que se guardan en `meals`.
    func handlePickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "No se pudo cargar la imagen"
                return
            }
            // Comprimir a JPEG max 2MB
            let compressed = compressImage(data: data, maxBytes: 2 * 1024 * 1024)
            pendingImageDescription = "Subiendo imagen..."

            // 1. Subir a Storage
            let url = try await StorageService.shared.uploadMealImage(data: compressed)
            pendingImageDescription = "Analizando comida..."
            AppLogger.info("Imagen subida: \(url)")

            // 2. Enviar al agente (que la descarga, analiza con vision, y guarda macros)
            let attachment = AgentAttachment(type: "image", url: url)
            await send("He subido una foto de comida. Analízala y dime las macros estimadas.", attachments: [attachment])
            pendingImageDescription = nil

            // 3. Borrar imagen de Storage (no la necesitamos, solo el análisis textual)
            await StorageService.shared.deleteMealImage(at: url)
        } catch {
            pendingImageDescription = nil
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

import UIKit

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