// ============================================================
// SettingsView - configuración ultra-personalizable
// ============================================================

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var showSignOutConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if let profile = auth.profile {
                    Section("Perfil") {
                        LabeledContent("Nombre", value: profile.fullName ?? "—")
                        LabeledContent("Objetivo", value: profile.goal ?? "—")
                        LabeledContent("Peso", value: profile.weightKg.map { "\($0) kg" } ?? "—")
                        LabeledContent("Altura", value: profile.heightCm.map { "\(Int($0)) cm" } ?? "—")
                        LabeledContent("Contexto", value: profile.householdContext ?? "—")
                    }
                }

                Section("Agente") {
                    NavigationLink("Personalidad del coach") {
                        Text("Próximamente: ajusta el tono, idioma, nivel de detalle.")
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("Alimentos favoritos") {
                        Text("Próximamente: lista de alimentos que te gustan o disgustan.")
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("Alérgenos y restricciones") {
                        Text("Próximamente: gestiona alérgenos y restricciones.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Salud") {
                    Button {
                        Task { try? await HealthKitManager.shared.syncToBackend(days: 30) }
                    } label: {
                        Label("Sincronizar HealthKit ahora", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section("Ayuda") {
                    Link(destination: URL(string: "https://github.com/your-user/nutricoach-ai/blob/main/docs/ONBOARDING-USER.md")!) {
                        Label("Cómo configurar tu iPhone", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Ajustes")
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showSignOutConfirm) {
                Button("Cerrar sesión", role: .destructive) {
                    Task { await auth.signOut() }
                }
                Button("Cancelar", role: .cancel) { }
            }
        }
    }
}
