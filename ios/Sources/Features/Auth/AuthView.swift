// ============================================================
// AuthView - Login / Sign up con email o Apple ID
// ============================================================

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var fullName: String = ""
    @State private var isSignUp: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    form
                    actions
                    appleSignInButton
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)
            }
            .background(Color(.systemBackground))
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)
            Text("NutriCoach")
                .font(.largeTitle)
                .bold()
            Text(isSignUp ? "Crea tu cuenta" : "Bienvenido de vuelta")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(spacing: 16) {
            if isSignUp {
                TextField("Nombre", text: $fullName)
                    .textContentType(.name)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            SecureField("Contraseña", text: $password)
                .textContentType(isSignUp ? .newPassword : .password)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await submit() }
            } label: {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(isSignUp ? "Crear cuenta" : "Entrar")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.green.gradient, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .disabled(isLoading || email.isEmpty || password.isEmpty)

            Button {
                isSignUp.toggle()
                errorMessage = nil
            } label: {
                Text(isSignUp ? "¿Ya tienes cuenta? Entra" : "¿No tienes cuenta? Regístrate")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
    }

    private var appleSignInButton: some View {
        VStack(spacing: 12) {
            HStack {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(.secondary.opacity(0.3))
                Text("o")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(.secondary.opacity(0.3))
            }
            .padding(.vertical, 4)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email, .fullName]
            } onCompletion: { result in
                Task { await handleAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .disabled(isLoading)
        }
    }

    private func submit() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            if isSignUp {
                try await auth.signUp(email: email, password: password, fullName: fullName.isEmpty ? nil : fullName)
            } else {
                try await auth.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Credencial de Apple no válida"
                return
            }
            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = "No se pudo obtener el token de identidad de Apple"
                return
            }
            do {
                try await auth.signInWithApple(idToken: identityToken, fullName: credential.fullName)
            } catch {
                errorMessage = "Error con Apple Sign In: \(error.localizedDescription)"
            }
        case .failure(let error):
            // Si el usuario cancela, no mostramos error
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = "Error con Apple Sign In: \(error.localizedDescription)"
            }
        }
    }
}