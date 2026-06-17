// ============================================================
// AuthManager - gestiona sesión de Supabase Auth
// Soporta email/password y Apple Sign In (futuro)
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

    private let supabase = SupabaseService.shared.client

    func restoreSession() async {
        do {
            let session = try await supabase.auth.session
            let user = session.user
            await loadProfile(userId: user.id)
            state = .signedIn(user: user)
            AppLogger.info("Sesión restaurada: \(user.id)")
        } catch {
            state = .signedOut
            AppLogger.info("Sin sesión activa")
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
        let signUpOptions = AuthOptions(
            data: fullName.map { ["full_name": .string($0)] }
        )
        let session = try await supabase.auth.signUp(
            email: email,
            password: password,
            options: signUpOptions
        )
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
