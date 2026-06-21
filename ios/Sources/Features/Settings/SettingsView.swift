// ============================================================
// SettingsView - configuracion de la app
// ============================================================

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @AppStorage("app.theme") private var themePreference: String = "system"
    @AppStorage("app.notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("app.hapticsEnabled") private var hapticsEnabled: Bool = true
    @State private var showSignOutConfirm: Bool = false
    @State private var showClearAllConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Perfil
                if let profile = auth.profile {
                    Section("Perfil") {
                        if let name = profile.fullName, !name.isEmpty {
                            LabeledContent("Nombre", value: name)
                        }
                        if let goal = profile.goal, !goal.isEmpty {
                            LabeledContent("Objetivo", value: goalLabel(goal))
                        }
                        if let weight = profile.weightKg {
                            LabeledContent("Peso", value: "\(Int(weight)) kg")
                        }
                        if let height = profile.heightCm {
                            LabeledContent("Altura", value: "\(Int(height)) cm")
                        }
                        if let target = profile.dailyKcalTarget {
                            LabeledContent("Kcal objetivo", value: "\(target) kcal/día")
                        }
                        NavigationLink {
                            ProfileSetupView()
                        } label: {
                            Label("Editar perfil completo", systemImage: "pencil")
                        }
                    }
                } else {
                    Section("Perfil") {
                        NavigationLink {
                            ProfileSetupView()
                        } label: {
                            Label("Configurar mi perfil", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                // MARK: - Apariencia
                Section("Apariencia") {
                    Picker("Tema", selection: $themePreference) {
                        Text("Sistema").tag("system")
                        Text("Claro").tag("light")
                        Text("Oscuro").tag("dark")
                    }
                }

                // MARK: - Notificaciones
                Section("Notificaciones") {
                    Toggle("Recordatorios", isOn: $notificationsEnabled)
                    if notificationsEnabled {
                        NavigationLink {
                            Text("Próximamente: configurar horarios de recordatorios")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Horarios", systemImage: "clock")
                        }
                    }
                }

                // MARK: - Salud
                Section("Salud") {
                    Button {
                        Task { await HealthKitManager.shared.syncToBackend(days: 30) }
                    } label: {
                        Label("Sincronizar HealthKit ahora", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                // MARK: - Experiencia
                Section("Experiencia") {
                    Toggle("Vibración al enviar", isOn: $hapticsEnabled)
                }

                // MARK: - Agente
                Section("Agente") {
                    NavigationLink {
                        Text("Próximamente: ajusta el tono del coach, nivel de detalle, idioma.")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Personalidad del coach", systemImage: "person.crop.circle")
                    }
                }

                // MARK: - Datos
                Section("Datos") {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Label("Borrar conversaciones", systemImage: "trash")
                    }
                }

                // MARK: - Sobre
                Section("Sobre") {
                    LabeledContent("Versión", value: "0.1.0")
                    Link(destination: URL(string: "https://github.com/jooelmortees/nutricoach-ai")!) {
                        Label("Código fuente", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                // MARK: - Sesión
                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Ajustes")
            .preferredColorScheme(colorScheme)
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showSignOutConfirm) {
                Button("Cerrar sesión", role: .destructive) {
                    Task { await auth.signOut() }
                }
                Button("Cancelar", role: .cancel) {}
            }
            .confirmationDialog("¿Borrar todas las conversaciones?", isPresented: $showClearAllConfirm) {
                Button("Borrar todo", role: .destructive) {
                    // TODO: implementar delete all conversations
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta acción no se puede deshacer. Se borrarán todas las conversaciones y mensajes de tu cuenta.")
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil  // system
        }
    }

    private func goalLabel(_ goal: String) -> String {
        switch goal {
        case "lose": return "Perder peso"
        case "gain": return "Ganar peso/músculo"
        default: return "Mantener"
        }
    }
}