// ============================================================
// AuthView - Login / Sign up con email o Google
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
                    googleSignInButton
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

    private var googleSignInButton: some View {
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

            Button {
                Task { await signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Text("G")
                        .font(.headline.bold())
                    Text("Continuar con Google")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.primary)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                }
            }
            .buttonStyle(.plain)
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

    private func signInWithGoogle() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await auth.signInWithGoogle()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            errorMessage = "Error iniciando sesión con Google: \(error.localizedDescription)"
        }
    }
}
