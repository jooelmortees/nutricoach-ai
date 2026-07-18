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
        authError = nil
        do {
            let session = try await supabase.auth.session
            let user = session.user
            state = .signedIn(user: user)
            do {
                try await loadProfile(userId: user.id)
                await refreshTrackingSnapshot(userId: user.id)
                AppLogger.info("Sesión restaurada: \(user.id)")
            } catch {
                authError = error.localizedDescription
                AppLogger.warning("Sesion valida, pero no se pudo cargar el perfil: \(error.localizedDescription)")
            }
        } catch {
            if let currentSession = supabase.auth.currentSession {
                state = .signedIn(user: currentSession.user)
                authError = error.localizedDescription
                AppLogger.warning("No se pudo validar la sesion guardada: \(error.localizedDescription)")
            } else {
                DailyTrackingService.shared.clearWidgetSnapshot()
                state = .signedOut
                AppLogger.info("No hay una sesion guardada")
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        try await completeSignIn(session: session)
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
        guard let session = response.session else {
            throw AuthManagerError.emailConfirmationRequired
        }
        guard session.user.id == response.user.id else {
            throw AuthManagerError.sessionUserMismatch
        }
        try await completeSignIn(session: session)
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
        try await completeSignIn(session: session)
    }

    func signOut() async {
        var signOutError: Error?
        do {
            try await supabase.auth.signOut()
        } catch {
            signOutError = error
            AppLogger.warning("No se pudo completar el cierre de sesion remoto: \(error.localizedDescription)")
        }

        let sharedSessionCleared: Bool
        do {
            sharedSessionCleared = try SharedAuthStorage().isSharedSessionCleared(
                key: SharedConfiguration.authStorageKey
            )
        } catch {
            authError = "No se pudo verificar el cierre de sesión del widget: \(error.localizedDescription)"
            return
        }

        if supabase.auth.currentSession != nil || !sharedSessionCleared {
            authError = signOutError?.localizedDescription ?? "No se pudo eliminar la sesión guardada."
            return
        }

        DailyTrackingService.shared.clearWidgetSnapshot()
        profile = nil
        authError = nil
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

    private func completeSignIn(session: Session) async throws {
        profile = nil
        authError = nil
        state = .signedIn(user: session.user)
        do {
            try await loadProfile(userId: session.user.id)
        } catch {
            authError = error.localizedDescription
            throw error
        }
        await refreshTrackingSnapshot(userId: session.user.id)
    }

    private func loadProfile(userId: UUID) async throws {
        let authenticatedUserId = try await supabase.auth.session.user.id
        guard authenticatedUserId == userId else {
            throw AuthManagerError.sessionUserMismatch
        }

        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        profile = profiles.first
    }

    /// Recarga el perfil desde Supabase. Usar tras actualizar campos del perfil.
    func refreshProfile() async throws {
        let userId = try await supabase.auth.session.user.id
        try await loadProfile(userId: userId)
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

private enum AuthManagerError: LocalizedError {
    case emailConfirmationRequired
    case sessionUserMismatch

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired:
            return "Revisa tu correo y confirma la cuenta antes de iniciar sesión."
        case .sessionUserMismatch:
            return "La sesion guardada no corresponde al usuario autenticado."
        }
    }
}
