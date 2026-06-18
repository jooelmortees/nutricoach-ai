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

    private let agent = AgentService.shared

    func loadOrCreateConversation() async {
        if currentConversationId == nil {
            await newConversation()
        }
    }

    func newConversation() async {
        do {
            let id = try await agent.createConversation()
            currentConversationId = id
            messages = []
        } catch {
            errorMessage = "No se pudo crear conversación: \(error.localizedDescription)"
        }
    }

    func send(_ text: String) async {
        guard !text.isEmpty, let convId = currentConversationId else { return }

        // 1. Añadir mensaje del usuario
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        isAgentThinking = true

        // 2. Crear placeholder del asistente
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        // 3. Enviar al agente
        await agent.sendMessage(
            conversationId: convId,
            message: text
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
        case .error(let msg):
            errorMessage = msg
            isAgentThinking = false
        }
    }

    func handlePickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            // En fase 1: subimos a Storage y mandamos URL al agente
            // Aquí simplificado: solo info de que hay imagen
            let data = try await item.loadTransferable(type: Data.self)
            guard let data else { return }

            // TODO fase 2: subir a Supabase Storage y obtener URL pública
            // Por ahora, mensaje placeholder
            await send("📷 [Imagen adjunta - \(data.count) bytes] (subida pendiente)")
        } catch {
            errorMessage = "Error procesando imagen: \(error.localizedDescription)"
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    var thinking: String?
    var isStreaming: Bool = false

    enum Role {
        case user, assistant
    }
}
