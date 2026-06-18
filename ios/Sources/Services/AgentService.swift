// ============================================================
// AgentService - cliente del agente (Edge Function chat-proxy)
// Maneja streaming con SSE
// ============================================================

import Foundation
import Supabase

enum AgentEvent {
    case thinkingDelta(String)
    case textDelta(String)
    case blockStart
    case blockStop
    case done
    case error(String)
}

@MainActor
final class AgentService: ObservableObject {
    static let shared = AgentService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Envía un mensaje al agente y emite eventos vía `onEvent`
    func sendMessage(
        conversationId: String,
        message: String,
        attachments: [AgentAttachment] = [],
        onEvent: @escaping (AgentEvent) -> Void
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
                message: message,
                attachments: attachments
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                onEvent(.error("HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
                return
            }

            for try await line in bytes.lines {
                if line.isEmpty || !line.hasPrefix("data:") { continue }
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let event = parseSSE(data: data) {
                    onEvent(event)
                }
            }
        } catch {
            onEvent(.error(error.localizedDescription))
        }
    }

    private func parseSSE(data: String) -> AgentEvent? {
        // El formato es: "event: <type>\ndata: <json>\n\n"
        // Aquí recibimos solo la parte de data (una línea). Para simplificar
        // el parser en el cliente, el backend podría enviar tipo+data en una sola línea.
        // Por ahora parseamos el JSON completo:
        guard let jsonData = data.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }

        if let text = obj["text"] as? String, let type = obj["type"] as? String {
            switch type {
            case "thinking": return .thinkingDelta(text)
            case "text": return .textDelta(text)
            default: break
            }
        }
        if let done = obj["done"] as? Bool, done { return .done }
        if let err = obj["message"] as? String { return .error(err) }
        return nil
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
}

struct AgentAttachment: Encodable {
    let type: String  // "image" | "video"
    let url: String
}

struct AgentRequest: Encodable {
    let conversation_id: String
    let message: String
    let attachments: [AgentAttachment]
}
