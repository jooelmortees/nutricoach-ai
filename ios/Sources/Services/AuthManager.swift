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
        do {
            let session = try await supabase.auth.session
            let user = session.user
            await loadProfile(userId: user.id)
            state = .signedIn(user: user)
            AppLogger.info("Sesión restaurada: \(user.id)")
        } catch {
            // Sin sesión activa: esto es normal en primer arranque
            state = .signedOut
            AppLogger.info("Sin sesión activa al arrancar")
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        await loadProfile(userId: session.user.id)
        state = .signedIn(user: session.user)
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
        await loadProfile(userId: response.user.id)
        state = .signedIn(user: response.user)
    }

    /// Sign In with Apple: extrae el identityToken de la credencial de Apple
    /// y lo envía a Supabase via `signInWithIdToken`. Si es la primera vez
    /// y tenemos el nombre completo, lo guardamos en user_metadata.
    func signInWithApple(idToken: String, fullName: PersonNameComponents?) async throws {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: idToken
            )
        )
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
        await loadProfile(userId: session.user.id)
        state = .signedIn(user: session.user)
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        profile = nil
        state = .signedOut
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
            AppLogger.warning("No se pudo cargar perfil: \(error.localizedDescription)")
        }
    }
}