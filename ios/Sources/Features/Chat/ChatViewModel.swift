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
    @Published var isSending: Bool = false
    @Published var currentConversationId: String?
    @Published var errorMessage: String?
    /// Lista de imagenes pendientes de enviar (aun no subidas a Storage).
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var isLoadingOlderMessages = false

    private let agent = AgentService.shared
    private let historyPageSize = 50
    private var oldestMessageCreatedAt: String?
    private var oldestMessageId: String?
    private var hasLoadedConversation = false
    private var streamTask: Task<Void, Never>?
    private var conversationGeneration = 0

    func loadOrCreateConversation() async {
        guard !hasLoadedConversation else { return }
        let generation = conversationGeneration
        do {
            if currentConversationId == nil {
                let id = try await agent.loadOrCreateLatestConversation()
                guard conversationGeneration == generation else { return }
                currentConversationId = id
            }
            if let convId = currentConversationId {
                let history = try await agent.loadHistory(
                    conversationId: convId,
                    limit: historyPageSize
                )
                guard conversationGeneration == generation, currentConversationId == convId else { return }
                let loadedMessages = await makeChatMessages(from: history)
                guard conversationGeneration == generation, currentConversationId == convId else { return }
                messages = loadedMessages
                oldestMessageCreatedAt = history.first?.createdAt
                oldestMessageId = history.first?.id
                hasMoreHistory = history.count == historyPageSize
            }
            hasLoadedConversation = true
        } catch {
            errorMessage = "No se pudo cargar historial: \(error.localizedDescription)"
        }
    }

    func loadOlderMessages() async {
        guard !isLoadingOlderMessages,
              hasMoreHistory,
              let convId = currentConversationId,
              let oldestMessageCreatedAt,
              let oldestMessageId else { return }

        isLoadingOlderMessages = true
        let generation = conversationGeneration
        defer { isLoadingOlderMessages = false }
        do {
            let history = try await agent.loadHistory(
                conversationId: convId,
                before: oldestMessageCreatedAt,
                beforeId: oldestMessageId,
                limit: historyPageSize
            )
            let olderMessages = await makeChatMessages(from: history)
            guard conversationGeneration == generation, currentConversationId == convId else { return }
            let existingIds = Set(messages.map(\.id))
            messages.insert(contentsOf: olderMessages.filter { !existingIds.contains($0.id) }, at: 0)
            self.oldestMessageCreatedAt = history.first?.createdAt ?? oldestMessageCreatedAt
            self.oldestMessageId = history.first?.id ?? oldestMessageId
            hasMoreHistory = history.count == historyPageSize
        } catch {
            errorMessage = "No se pudieron cargar mensajes anteriores: \(error.localizedDescription)"
        }
    }

    func newConversation() async {
        conversationGeneration += 1
        cancelActiveStream()
        do {
            let id = try await agent.createConversation()
            currentConversationId = id
            messages = []
            errorMessage = nil
            pendingAttachments = []
            oldestMessageCreatedAt = nil
            oldestMessageId = nil
            hasMoreHistory = false
            hasLoadedConversation = true
        } catch {
            errorMessage = "No se pudo crear conversación: \(error.localizedDescription)"
        }
    }

    /// Limpia la conversacion actual: borra todos los mensajes y adjuntos pendientes.
    func clearConversation() {
        conversationGeneration += 1
        cancelActiveStream()
        messages = []
        errorMessage = nil
        pendingAttachments = []
        oldestMessageCreatedAt = nil
        oldestMessageId = nil
        hasMoreHistory = false
    }

    /// Regenera la respuesta seleccionada y descarta los turnos posteriores.
    @discardableResult
    func regenerateResponse(for assistantMessageId: UUID) async -> Bool {
        guard !isSending, !isAgentThinking,
              let conversationId = currentConversationId,
              let assistantIndex = messages.firstIndex(where: {
                  $0.id == assistantMessageId && $0.role == .assistant
              }),
              let userIndex = messages[..<assistantIndex].lastIndex(where: {
                  $0.role == .user
              }) else { return false }

        let generation = conversationGeneration
        let userMessage = messages[userIndex]
        let attachments = reusableAttachments(from: userMessage)
        guard attachments.count == (userMessage.attachments?.count ?? 0) else {
            errorMessage = "No se puede reutilizar un mensaje con adjuntos antiguos."
            return false
        }
        guard !userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else {
            errorMessage = "No se puede regenerar este mensaje."
            return false
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await agent.deleteMessages(
                ids: messages.suffix(from: userIndex + 1).map(\.id)
            )
        } catch {
            errorMessage = "No se pudo regenerar la respuesta: \(error.localizedDescription)"
            return false
        }
        guard conversationGeneration == generation,
              currentConversationId == conversationId else { return false }

        messages = Array(messages.prefix(userIndex + 1))
        isAgentThinking = true
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        startStream(
            conversationId: conversationId,
            clientMessageId: userMessage.id,
            message: userMessage.content,
            attachments: attachments,
            assistantMessageId: assistantMessage.id,
            webSearch: false
        )
        return true
    }

    /// Sustituye un mensaje del usuario y vuelve a generar la conversación desde él.
    @discardableResult
    func editMessage(id messageId: UUID, content: String) async -> Bool {
        guard !isSending, !isAgentThinking,
              let conversationId = currentConversationId,
              let userIndex = messages.firstIndex(where: {
                  $0.id == messageId && $0.role == .user
              }) else { return false }

        let editedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalMessage = messages[userIndex]
        let attachments = reusableAttachments(from: originalMessage)
        guard attachments.count == (originalMessage.attachments?.count ?? 0) else {
            errorMessage = "No se puede editar un mensaje con adjuntos antiguos."
            return false
        }
        guard !editedContent.isEmpty || !attachments.isEmpty else {
            errorMessage = "El mensaje no puede quedar vacío."
            return false
        }
        guard editedContent != originalMessage.content else { return true }

        let generation = conversationGeneration
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await agent.deleteMessages(
                ids: messages.suffix(from: userIndex).map(\.id)
            )
        } catch {
            errorMessage = "No se pudo editar el mensaje: \(error.localizedDescription)"
            return false
        }
        guard conversationGeneration == generation,
              currentConversationId == conversationId else { return false }

        let editedMessage = ChatMessage(
            role: .user,
            content: editedContent,
            attachments: originalMessage.attachments
        )
        messages = Array(messages.prefix(userIndex)) + [editedMessage]
        isAgentThinking = true
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        startStream(
            conversationId: conversationId,
            clientMessageId: editedMessage.id,
            message: editedContent,
            attachments: attachments,
            assistantMessageId: assistantMessage.id,
            webSearch: false
        )
        return true
    }

    /// Quita una imagen pendiente por su id (boton X del preview).
    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Limpia todas las imagenes pendientes.
    func clearPendingAttachments() {
        pendingAttachments = []
    }

    /// Envia un mensaje al agente. Sube imagenes, adjunta audio si hay,
    /// y limpia el estado de preview.
    @discardableResult
    func send(text: String, recordedAudio: RecordedAudio? = nil, webSearch: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        let hasAudio = recordedAudio != nil
        guard hasText || hasAttachments || hasAudio else { return false }
        guard pendingAttachments.count + (hasAudio ? 1 : 0) <= 8 else {
            errorMessage = "Puedes enviar hasta ocho adjuntos, incluido el audio."
            return false
        }
        guard !isSending, !isAgentThinking else { return false }
        guard let convId = currentConversationId else {
            errorMessage = "No hay conversacion activa."
            return false
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        var displayAttachments: [MessageAttachment] = []
        var agentAttachments: [AgentAttachment] = []
        let toUpload = pendingAttachments
        for attachment in toUpload {
            do {
                let uploaded = try await StorageService.shared.uploadChatImage(
                    data: attachment.imageData,
                    conversationId: convId
                )
                displayAttachments.append(uploaded)
                agentAttachments.append(uploaded.agentAttachment)
            } catch {
                await StorageService.shared.deleteChatAttachments(displayAttachments)
                errorMessage = "Error con la imagen: \(error.localizedDescription)"
                return false
            }
        }

        if let recordedAudio {
            do {
                let uploaded = try await StorageService.shared.uploadChatAudio(
                    recordedAudio,
                    conversationId: convId
                )
                displayAttachments.append(uploaded)
                agentAttachments.append(uploaded.agentAttachment)
            } catch {
                await StorageService.shared.deleteChatAttachments(displayAttachments)
                errorMessage = "Error con el audio: \(error.localizedDescription)"
                return false
            }
        }

        guard currentConversationId == convId else {
            await StorageService.shared.deleteChatAttachments(displayAttachments)
            return false
        }
        pendingAttachments = []

        let userMsg = ChatMessage(
            role: .user,
            content: trimmed,
            attachments: displayAttachments
        )
        messages.append(userMsg)
        isAgentThinking = true
        errorMessage = nil

        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        startStream(
            conversationId: convId,
            clientMessageId: userMsg.id,
            message: trimmed,
            attachments: agentAttachments,
            assistantMessageId: assistantMsg.id,
            webSearch: webSearch
        )
        return true
    }

    private func handle(event: AgentEvent, assistantMessageId: UUID, conversationId: String) {
        switch event {
        case .toolDone(let name, _) where name == "log_water":
            refreshTrackingSnapshot()
        case .mealSaved(_, _, _, _, _):
            refreshTrackingSnapshot()
        default:
            break
        }

        guard currentConversationId == conversationId,
              let idx = messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
        switch event {
        case .thinkingDelta(let text):
            messages[idx].thinking = (messages[idx].thinking ?? "") + text
        case .textDelta(let text):
            messages[idx].content += text
        case .blockStart, .blockStop:
            break
        case .toolsStart(let names):
            // El agente empieza a usar tools. Mostrar indicador en el mensaje.
            var statusList: [ToolStatus] = []
            for name in names {
                statusList.append(ToolStatus(name: name, summary: "", isRunning: true))
            }
            messages[idx].toolStatus = statusList
        case .toolDone(let name, let summary):
            // Marcar el tool como completado y actualizar el summary
            if var tools = messages[idx].toolStatus {
                if let toolIdx = tools.firstIndex(where: { $0.name == name }) {
                    tools[toolIdx].isRunning = false
                    if !summary.isEmpty {
                        tools[toolIdx].summary = summary
                    }
                } else {
                    tools.append(ToolStatus(name: name, summary: summary, isRunning: false))
                }
                messages[idx].toolStatus = tools
            }
        case .done:
            messages[idx].isStreaming = false
            messages[idx].toolStatus = nil
            isAgentThinking = false
        case .mealSaved(let kcal, let protein, let carbs, let fat, let description):
            let summary = formatMealSummary(kcal: kcal, protein: protein, carbs: carbs, fat: fat)
            messages.append(ChatMessage(
                role: .assistant,
                content: "[Comida guardada] \(description)\n\(summary)\n\nRegistrada en tu pestana Macros."
            ))
        case .error(let msg):
            errorMessage = msg
            isAgentThinking = false
            if messages[idx].role == .assistant && messages[idx].isStreaming {
                messages[idx].isStreaming = false
                if messages[idx].content.isEmpty {
                    messages[idx].content = "Error: \(msg)"
                }
            }
        }
    }

    private func refreshTrackingSnapshot() {
        Task {
            do {
                try await DailyTrackingService.shared.refreshWidgetSnapshot()
            } catch {
                AppLogger.warning("No se pudo refrescar el widget desde el chat: \(error.localizedDescription)")
            }
        }
    }

    private func startStream(
        conversationId: String,
        clientMessageId: UUID,
        message: String,
        attachments: [AgentAttachment],
        assistantMessageId: UUID,
        webSearch: Bool
    ) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.agent.sendMessage(
                conversationId: conversationId,
                clientMessageId: clientMessageId,
                assistantMessageId: assistantMessageId,
                message: message,
                attachments: attachments,
                webSearch: webSearch
            ) { [weak self] event in
                guard let self else { return }
                self.handle(
                    event: event,
                    assistantMessageId: assistantMessageId,
                    conversationId: conversationId
                )
            }
        }
    }

    private func cancelActiveStream() {
        streamTask?.cancel()
        streamTask = nil
        isAgentThinking = false
        isSending = false
    }

    private func reusableAttachments(from message: ChatMessage) -> [AgentAttachment] {
        message.attachments?
            .filter { $0.bucket != nil && $0.path != nil }
            .map(\.agentAttachment) ?? []
    }

    private func makeChatMessages(from history: [HistoryMessage]) async -> [ChatMessage] {
        var result: [ChatMessage] = []
        result.reserveCapacity(history.count)
        for item in history {
            let attachments = await StorageService.shared.refreshAccessURLs(in: item.attachments)
            result.append(ChatMessage(
                id: UUID(uuidString: item.id) ?? UUID(),
                role: item.role,
                content: item.content,
                thinking: item.thinking,
                attachments: attachments,
                isStreaming: false
            ))
        }
        return result
    }

    /// El usuario seleccionó N imagenes del PhotosPicker. Las añadimos al
    /// preview sin subirlas todavia (se subiran al enviar).
    func handlePickedImages(_ items: [PhotosPickerItem]) async {
        let availableSlots = max(8 - pendingAttachments.count, 0)
        if items.count > availableSlots {
            errorMessage = "Puedes adjuntar hasta ocho archivos."
        }
        for item in items.prefix(availableSlots) {
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

    /// Guarda una comida (parseada del JSON de Gemini) en la tabla `meals` del usuario.
    /// Usado por el boton "Guardar en mi dia" que aparece cuando Gemini devuelve
    /// macros en formato JSON.
    ///
    /// Mapeo entre `PendingMeal` (lo que viene del JSON de Gemini) y la tabla `meals`:
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
            do {
                try await DailyTrackingService.shared.refreshWidgetSnapshot(
                    userId: UUID(uuidString: userId)
                )
            } catch {
                AppLogger.warning("No se pudo refrescar el widget tras guardar comida: \(error.localizedDescription)")
            }
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
    let id: UUID
    let type: String
    let bucket: String?
    let path: String?
    var url: String?
    let mimeType: String?
    let name: String?
    let sizeBytes: Int?
    let durationSeconds: Double?
    let legacyData: String?

    init(
        id: UUID = UUID(),
        type: String,
        bucket: String? = nil,
        path: String? = nil,
        url: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
        sizeBytes: Int? = nil,
        durationSeconds: Double? = nil,
        legacyData: String? = nil
    ) {
        self.id = id
        self.type = type
        self.bucket = bucket
        self.path = path
        self.url = url
        self.mimeType = mimeType
        self.name = name
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.legacyData = legacyData
    }

    enum CodingKeys: String, CodingKey {
        case type, bucket, path, url, data, mimeType = "mime_type"
        case name, sizeBytes = "size_bytes", durationSeconds = "duration_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        // type y url son opcionales en BD: los attachments de audio
        // guardan solo {data, mime_type} sin type ni url. Si falta
        // type, inferimos por presencia de data/url.
        let typeStr = try container.decodeIfPresent(String.self, forKey: .type)
        let urlStr = try container.decodeIfPresent(String.self, forKey: .url)
        let dataStr = try container.decodeIfPresent(String.self, forKey: .data)
        if let t = typeStr {
            self.type = t
        } else if dataStr != nil {
            self.type = "audio"
        } else {
            self.type = "image"
        }
        self.bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.url = urlStr
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
        self.durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.legacyData = dataStr
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(bucket, forKey: .bucket)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }

    static func == (lhs: MessageAttachment, rhs: MessageAttachment) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.bucket == rhs.bucket &&
        lhs.path == rhs.path &&
        lhs.url == rhs.url &&
        lhs.mimeType == rhs.mimeType &&
        lhs.name == rhs.name &&
        lhs.sizeBytes == rhs.sizeBytes &&
        lhs.durationSeconds == rhs.durationSeconds &&
        lhs.legacyData == rhs.legacyData
    }

    var agentAttachment: AgentAttachment {
        AgentAttachment(
            type: type,
            bucket: bucket,
            path: path,
            url: bucket == nil ? url : nil,
            data: legacyData,
            mime_type: mimeType,
            name: name,
            size_bytes: sizeBytes,
            duration_seconds: durationSeconds
        )
    }
}

struct ChatMessage: Identifiable, Equatable {
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

    enum Role: Equatable {
        case user, assistant
    }
}
