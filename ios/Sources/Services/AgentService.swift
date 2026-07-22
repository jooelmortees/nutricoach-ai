// ============================================================
// AgentService - cliente del agente (Edge Function chat-proxy)
// Maneja streaming con SSE (Server-Sent Events)
// ============================================================

import Foundation
import Supabase

enum AgentEvent {
    case thinkingDelta(String)
    case textDelta(String)
    case blockStart
    case blockStop
    case toolsStart(names: [String])
    case toolDone(name: String, summary: String)
    case done
    case mealSaved(kcal: Double?, protein: Double?, carbs: Double?, fat: Double?, description: String)
    case error(String)
}

final class AgentService {
    static let shared = AgentService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Envía un mensaje al agente y emite eventos vía `onEvent`.
    /// Parsea SSE en formato estándar: `event: <type>\ndata: <json>\n\n`.
    func sendMessage(
        conversationId: String,
        clientMessageId: UUID,
        assistantMessageId: UUID,
        message: String,
        attachments: [AgentAttachment] = [],
        webSearch: Bool = false,
        onEvent: @escaping @MainActor (AgentEvent) -> Void
    ) async {
        do {
            let token = try await SupabaseService.shared.client.auth.session.accessToken
            let url = Config.chatProxyURL
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            let body = AgentRequest(
                conversation_id: conversationId,
                client_message_id: clientMessageId.uuidString.lowercased(),
                assistant_message_id: assistantMessageId.uuidString.lowercased(),
                message: message,
                attachments: attachments,
                web_search: webSearch
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                await onEvent(.error("HTTP error: \(status)"))
                return
            }

            // Parser SSE: lee líneas, agrupa por bloques separados por línea
            // vacía. Cada bloque es `event: <type>\ndata: <json>`.
            var currentEvent: String?
            var receivedDone = false
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                if line.isEmpty {
                    currentEvent = nil
                    continue
                }
                if line.hasPrefix("event:") {
                    currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let event = parseSSE(type: currentEvent, data: data) {
                        if case .done = event {
                            receivedDone = true
                        }
                        await onEvent(event)
                    }
                }
            }
            // SAFETY NET: si el stream termina sin un evento 'done' (porque el
            // servidor no lo emite, timeout, red inestable, etc.) forzamos
            // 'done' para que el UI no quede con isAgentThinking=true para siempre.
            if !receivedDone {
                AppLogger.warning("Stream SSE termino sin evento 'done'. Forzando done.")
                await onEvent(.done)
            }
        } catch {
            await onEvent(.error(error.localizedDescription))
            // Incluso si hubo error, emitir 'done' para resetear el UI
            await onEvent(.done)
        }
    }

    private func parseSSE(type: String?, data: String) -> AgentEvent? {
        guard let jsonData = data.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }

        switch type {
        case "thinking":
            if let text = obj["text"] as? String { return .thinkingDelta(text) }
        case "text":
            if let text = obj["text"] as? String { return .textDelta(text) }
        case "block_start": return .blockStart
        case "block_stop": return .blockStop
        case "tools_start":
            if let names = obj["names"] as? [String] {
                return .toolsStart(names: names)
            }
            return nil
        case "tool_done":
            if let name = obj["name"] as? String {
                let summary = (obj["summary"] as? String) ?? ""
                return .toolDone(name: name, summary: summary)
            }
            return nil
        case "done": return .done
        case "meal_saved":
            return .mealSaved(
                kcal: (obj["kcal"] as? NSNumber)?.doubleValue,
                protein: (obj["protein_g"] as? NSNumber)?.doubleValue,
                carbs: (obj["carbs_g"] as? NSNumber)?.doubleValue,
                fat: (obj["fat_g"] as? NSNumber)?.doubleValue,
                description: obj["description"] as? String ?? "Comida registrada"
            )
        case "error":
            if let msg = obj["message"] as? String { return .error(msg) }
            if let msg = obj["error"] as? String { return .error(msg) }
        default:
            break
        }
        return nil
    }

    /// Carga el historial de mensajes de una conversación.
    func loadHistory(
        conversationId: String,
        before createdAt: String? = nil,
        beforeId: String? = nil,
        limit: Int = 50
    ) async throws -> [HistoryMessage] {
        struct Row: Decodable {
            let id: UUID
            let role: String
            let content: String
            let thinking: String?
            let attachments: [MessageAttachment]?
            let created_at: String
        }
        let supabase = SupabaseService.shared.client
        let rows: [Row]
        if let createdAt, let beforeId {
            rows = try await supabase
                .from("messages")
                .select("id,role,content,thinking,attachments,created_at")
                .eq("conversation_id", value: conversationId)
                .or("created_at.lt.\(createdAt),and(created_at.eq.\(createdAt),id.lt.\(beforeId))")
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(limit)
                .execute()
                .value
        } else {
            rows = try await supabase
                .from("messages")
                .select("id,role,content,thinking,attachments,created_at")
                .eq("conversation_id", value: conversationId)
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(limit)
                .execute()
                .value
        }

        return rows.reversed().map { row in
            HistoryMessage(
                id: row.id.uuidString,
                role: row.role == "user" ? .user : .assistant,
                content: row.content,
                thinking: row.thinking,
                attachments: row.attachments ?? [],
                createdAt: row.created_at
            )
        }
    }

    func deleteMessages(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let supabase = SupabaseService.shared.client
        try await supabase
            .from("messages")
            .delete()
            .in("id", values: ids.map(\.uuidString))
            .execute()
    }

    /// Crea una conversación nueva
    func createConversation() async throws -> String {
        let supabase = SupabaseService.shared.client
        let userId = try await supabase.auth.session.user.id
        struct NewConv: Encodable {
            let user_id: String
            let title: String
        }
        let response: Conversation = try await supabase
            .from("conversations")
            .insert(NewConv(user_id: userId.uuidString, title: "Nueva conversación"))
            .select()
            .single()
            .execute()
            .value
        return response.id.uuidString
    }

    /// Carga (o crea si no hay) la conversación más reciente del usuario.
    func loadOrCreateLatestConversation() async throws -> String {
        struct ConvRow: Decodable {
            let id: UUID
        }
        let supabase = SupabaseService.shared.client
        let userId = try await supabase.auth.session.user.id
        let existing: [ConvRow] = try await supabase
            .from("conversations")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .order("last_message_at", ascending: false)
            .limit(1)
            .execute()
            .value
        if let first = existing.first {
            return first.id.uuidString
        }
        return try await createConversation()
    }
}

struct AgentAttachment: Encodable {
    let type: String  // "image" | "audio"
    let bucket: String?
    let path: String?
    let url: String?
    let data: String?
    let mime_type: String?
    let name: String?
    let size_bytes: Int?
    let duration_seconds: Double?

    init(
        type: String,
        bucket: String? = nil,
        path: String? = nil,
        url: String? = nil,
        data: String? = nil,
        mime_type: String? = nil,
        name: String? = nil,
        size_bytes: Int? = nil,
        duration_seconds: Double? = nil
    ) {
        self.type = type
        self.bucket = bucket
        self.path = path
        self.url = url
        self.data = data
        self.mime_type = mime_type
        self.name = name
        self.size_bytes = size_bytes
        self.duration_seconds = duration_seconds
    }
}

struct AgentRequest: Encodable {
    let conversation_id: String
    let client_message_id: String
    let assistant_message_id: String
    let message: String
    let attachments: [AgentAttachment]
    let web_search: Bool
}

/// Mensaje cargado del historial (distinto de ChatMessage que es el del VM).
struct HistoryMessage: Identifiable {
    let id: String
    let role: ChatMessage.Role
    let content: String
    let thinking: String?
    let attachments: [MessageAttachment]
    let createdAt: String
}
