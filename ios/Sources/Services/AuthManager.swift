// ============================================================
// AuthManager - gestiona sesión de Supabase Auth
// Soporta email/password, sign-up y Sign In with Apple
// ============================================================

import Foundation
import SwiftUI
import Supabase
import AuthenticationServices

enum AuthState {
    case loading
    case signedOut
    case signedIn(user: User)
}

@MainActor
final class AuthManager: ObservableObject {
    @Published var state: AuthState = .loading
    @Published var profile: Profile?
    @Published var authError: String?

    private let supabase = SupabaseService.shared.client

    func restoreSession() async {
        profile = nil
        do {
            let session = try await supabase.auth.session
            let user = session.user
            await loadProfile(userId: user.id)
            state = .signedIn(user: user)
            await refreshTrackingSnapshot(userId: user.id)
            AppLogger.info("Sesión restaurada: \(user.id)")
        } catch {
            do {
                try await supabase.auth.signOut(scope: .local)
            } catch {
                AppLogger.warning("No se pudo limpiar la sesion local: \(error.localizedDescription)")
            }
            DailyTrackingService.shared.clearWidgetSnapshot()
            state = .signedOut
            AppLogger.info("No se pudo restaurar una sesion valida")
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        profile = nil
        await loadProfile(userId: session.user.id)
        state = .signedIn(user: session.user)
        await refreshTrackingSnapshot(userId: session.user.id)
    }

    func signUp(email: String, password: String, fullName: String?) async throws {
        var userData: [String: AnyJSON]? = nil
        if let name = fullName, !name.isEmpty {
            userData = ["full_name": .string(name)]
        }
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: userData
        )
        profile = nil
        await loadProfile(userId: response.user.id)
        state = .signedIn(user: response.user)
        await refreshTrackingSnapshot(userId: response.user.id)
    }

    /// Sign In with Apple: extrae el identityToken de la credencial de Apple
    /// y lo envía a Supabase via `signInWithIdToken`. Si es la primera vez
    /// y tenemos el nombre completo, lo guardamos en user_metadata.
    func signInWithApple(idToken: String, fullName: PersonNameComponents?) async throws {
        AppLogger.info("Apple Sign In: idToken length=\(idToken.count)")
        let session: Session
        do {
            session = try await supabase.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken
                )
            )
        } catch {
            AppLogger.error("Apple Sign In failed: \(error.localizedDescription)")
            throw error
        }
        AppLogger.info("Apple Sign In OK: user=\(session.user.id)")
        // Solo la PRIMERA vez Apple envía el nombre completo. Las siguientes
        // veces es nil. Si llega, lo guardamos en user_metadata.
        if let components = fullName {
            let formatter = PersonNameComponentsFormatter()
            let fullNameString = formatter.string(from: components).trimmingCharacters(in: .whitespaces)
            if !fullNameString.isEmpty {
                _ = try? await supabase.auth.update(
                    user: UserAttributes(data: ["full_name": .string(fullNameString)])
                )
            }
        }
        profile = nil
        await loadProfile(userId: session.user.id)
        state = .signedIn(user: session.user)
        await refreshTrackingSnapshot(userId: session.user.id)
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        DailyTrackingService.shared.clearWidgetSnapshot()
        profile = nil
        state = .signedOut
    }

    /// Elimina permanentemente la cuenta del usuario y todos sus datos.
    /// Llama a la Edge Function `delete-account` que usa service_role para
    /// borrar tablas + Storage + auth.users. Tras confirmar, cierra sesión.
    func deleteAccount() async throws {
        let url = Config.supabaseURL.appending(path: "functions/v1/delete-account")
        let token = try await supabase.auth.session.accessToken
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "?"
            throw AuthError.deleteFailed("HTTP \(statusCode): \(body)")
        }
        // Si todo fue bien, cerrar sesion local
        try? await supabase.auth.signOut()
        DailyTrackingService.shared.clearWidgetSnapshot()
        profile = nil
        state = .signedOut
        AppLogger.info("Cuenta eliminada permanentemente")
    }

    /// Borra todas las conversaciones y mensajes del usuario.
    func clearAllConversations() async throws {
        let userId = try await supabase.auth.session.user.id
        // Borrar mensajes primero (FK a conversations)
        try await supabase
            .from("messages")
            .delete()
            .in("conversation_id", value: try await getConversationIds(userId: userId))
            .execute()
        // Borrar conversaciones
        try await supabase
            .from("conversations")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .execute()
        AppLogger.info("Conversaciones borradas para usuario \(userId)")
    }

    private func getConversationIds(userId: UUID) async throws -> [String] {
        struct ConvRow: Decodable { let id: UUID }
        let rows: [ConvRow] = try await supabase
            .from("conversations")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value
        return rows.map { $0.id.uuidString }
    }

    private func loadProfile(userId: UUID) async {
        do {
            let response: Profile = try await SupabaseService.shared.client
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            self.profile = response
        } catch {
            // La fila no existe en profiles (trigger fallo o usuario creado
            // antes de la migracion 0006). Crear fila vacia con upsert para
            // que el onboarding pueda hacer update despues.
            AppLogger.warning("Perfil no encontrado, creando fila vacia: \(error.localizedDescription)")
            await createEmptyProfile(userId: userId)
        }
    }

    private func createEmptyProfile(userId: UUID) async {
        struct EmptyProfile: Encodable {
            let id: String
            let full_name: String?
        }
        let payload = EmptyProfile(
            id: userId.uuidString,
            full_name: nil
        )
        do {
            try await SupabaseService.shared.client
                .from("profiles")
                .upsert(payload, onConflict: "id")
                .execute()
            // Recargar para que profile no sea nil
            let response: Profile = try await SupabaseService.shared.client
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            self.profile = response
        } catch {
            AppLogger.error("No se pudo crear perfil vacio: \(error.localizedDescription)")
        }
    }

    /// Recarga el perfil desde Supabase. Usar tras actualizar campos del perfil.
    func refreshProfile() async {
        guard let userId = profile?.id else { return }
        await loadProfile(userId: userId)
    }

    private func refreshTrackingSnapshot(userId: UUID) async {
        guard profile != nil else { return }
        do {
            try await DailyTrackingService.shared.refreshWidgetSnapshot(userId: userId)
        } catch {
            AppLogger.warning("No se pudo actualizar el widget tras autenticar: \(error.localizedDescription)")
        }
    }
}

enum AuthError: LocalizedError {
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let msg): return "No se pudo eliminar la cuenta: \(msg)"
        }
    }
}
