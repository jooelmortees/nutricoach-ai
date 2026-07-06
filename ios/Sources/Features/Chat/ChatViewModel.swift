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
    private var textThrottler: TextThrottler?

    func loadOrCreateConversation() async {
        do {
            if currentConversationId == nil {
                let id = try await agent.loadOrCreateLatestConversation()
                currentConversationId = id
                AppLogger.info("Conversacion cargada: \(id)")
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
                AppLogger.info("Historial cargado: \(history.count) mensajes")
            }
        } catch {
            AppLogger.error("Error cargando conversacion: \(error)")
            errorMessage = "No se pudo cargar el chat: \(error.localizedDescription)"
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

    /// Limpia la conversacion actual: borra todos los mensajes y adjuntos pendientes.
    func clearConversation() {
        messages = []
        errorMessage = nil
        pendingAttachments = []
    }

    /// Regenera la ultima respuesta del asistente. Toma el ultimo mensaje del
    /// usuario, lo reenvia, y reemplaza la respuesta del asistente.
    func regenerateLastResponse() async {
        guard currentConversationId != nil else { return }
        // Buscar el ultimo user message
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let lastUser = messages[lastUserIdx]
        // Eliminar todos los mensajes posteriores al user (assistant + posteriores)
        let newMessages = Array(messages.prefix(lastUserIdx + 1))
        messages = newMessages
        // Reenviar (sin adjuntos, ya estan en BD)
        isAgentThinking = true
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        await agent.sendMessage(
            conversationId: currentConversationId!,
            message: lastUser.content,
            attachments: []
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.handle(event: event)
            }
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
            // Throttle: acumular tokens y volcar a UI cada ~80ms
            // para evitar que SwiftUI congele en mensajes largos.
            if textThrottler == nil {
                textThrottler = TextThrottler(interval: 0.08) { [weak self] chunk in
                    guard let self, let idx = self.messages.indices.last else { return }
                    self.messages[idx].content += chunk
                }
            }
            textThrottler?.append(text)
        case .blockStart, .blockStop:
            break
        case .toolsStart(let names):
            // El agente empieza a usar tools. Mostrar indicador en el mensaje.
            if let idx = messages.indices.last {
                var statusList: [ToolStatus] = []
                for name in names {
                    statusList.append(ToolStatus(name: name, summary: "", isRunning: true))
                }
                messages[idx].toolStatus = statusList
            }
        case .toolDone(let name, let summary):
            // Marcar el tool como completado y actualizar el summary
            if let idx = messages.indices.last {
                if var tools = messages[idx].toolStatus {
                    if let toolIdx = tools.firstIndex(where: { $0.name == name }) {
                        tools[toolIdx].isRunning = false
                        if !summary.isEmpty {
                            tools[toolIdx].summary = summary
                        }
                    } else {
                        // Tool no estaba en la lista, lo añadimos como completado
                        tools.append(ToolStatus(name: name, summary: summary, isRunning: false))
                    }
                    messages[idx].toolStatus = tools
                }
            }
        case .done:
            // Flush final: volcar cualquier texto pendiente del throttler
            textThrottler?.flushNow()
            textThrottler = nil
            if let idx = messages.indices.last {
                messages[idx].isStreaming = false
                // Limpiar el estado de tools al terminar
                messages[idx].toolStatus = nil
            }
            isAgentThinking = false
        case .mealSaved(let kcal, let protein, let carbs, let fat, let description):
            let summary = formatMealSummary(kcal: kcal, protein: protein, carbs: carbs, fat: fat)
            messages.append(ChatMessage(
                role: .assistant,
                content: "🍽️ \(description)\n\(summary)\n\nRegistrada en tu pestaña Macros."
            ))
        case .error(let msg):
            textThrottler?.flushNow()
            textThrottler = nil
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
    ///
    /// Mapeo entre `PendingMeal` (lo que viene del JSON de M3) y la tabla `meals`:
    /// - `description`  -> `name`  (la tabla no tiene `description`)
    /// - `kcal`         -> `total_kcal`
    /// - `protein_g`    -> `total_protein_g`
    /// - `carbs_g`      -> `total_carbs_g`
    /// - `fat_g`        -> `total_fat_g`
    /// - `confidence`   -> `notes` (text, guarda el score)
    @discardableResult
    func saveMeal(_ meal: PendingMeal) async -> Bool {
        // 1. Obtener userId del cliente Supabase (sesion activa)
        let userId: String
        do {
            userId = try await SupabaseService.shared.client.auth.session.user.id.uuidString
        } catch {
            errorMessage = "Error de sesion: \(error.localizedDescription)"
            return false
        }

        // 2. Insertar en meals con los nombres REALES de columnas
        struct InsertPayload: Encodable {
            let user_id: String
            let name: String
            let meal_type: String?
            let total_kcal: Double?
            let total_protein_g: Double?
            let total_carbs_g: Double?
            let total_fat_g: Double?
            let source: String
            let notes: String?
        }
        // Notes guarda provenance estructurada (confidence, source) para
        // analisis posterior. Es text simple para evitar AnyEncodable.
        var notesParts: [String] = []
        if let conf = meal.confidence {
            notesParts.append("confidence=\(conf)")
        }
        if let ings = meal.ingredients, !ings.isEmpty {
            let ingsStr = ings.map { "\($0.name):\($0.quantity ?? 0)\($0.unit)" }.joined(separator: ", ")
            notesParts.append("ingredients=\(ingsStr)")
        }
        notesParts.append("source=ai")
        let notes = notesParts.joined(separator: " ")

        let payload = InsertPayload(
            user_id: userId,
            name: meal.description,
            meal_type: meal.meal_type,
            total_kcal: meal.kcal,
            total_protein_g: meal.protein_g,
            total_carbs_g: meal.carbs_g,
            total_fat_g: meal.fat_g,
            source: "ai_suggestion",
            notes: notes
        )

        do {
            try await SupabaseService.shared.client
                .from("meals")
                .insert(payload)
                .execute()
            // Mensaje de confirmacion en el chat
            messages.append(ChatMessage(
                role: .assistant,
                content: "Guardado: **\(meal.description)** en tu registro de comidas del dia."
            ))
            return true
        } catch {
            errorMessage = "Error guardando comida: \(error.localizedDescription)"
            return false
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
    var toolStatus: [ToolStatus]?
    var isStreaming: Bool = false

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        thinking: String? = nil,
        attachments: [MessageAttachment]? = nil,
        toolStatus: [ToolStatus]? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.attachments = attachments
        self.toolStatus = toolStatus
        self.isStreaming = isStreaming
    }

    enum Role {
        case user, assistant
    }
}