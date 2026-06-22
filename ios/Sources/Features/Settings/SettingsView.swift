// ============================================================
// SettingsView - configuracion de la app
// ============================================================

import SwiftUI
import HealthKit

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var healthKit = HealthKitManager.shared
    @AppStorage("app.theme") private var themePreference: String = "system"
    @AppStorage("app.notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("app.hapticsEnabled") private var hapticsEnabled: Bool = true
    @State private var showSignOutConfirm: Bool = false
    @State private var showClearAllConfirm: Bool = false
    @State private var lastSyncDate: Date? = nil
    @State private var isConnectingHealthKit: Bool = false
    @State private var healthKitError: String? = nil

    // Clave compartida con HealthKitManager para leer el timestamp de ultima sync.
    // La fuente de verdad es `HealthKitManager.lastSyncKey` (privado al modulo);
    // usamos el mismo literal para evitar exponer API publica.
    private let lastSyncKey = "hk_last_sync_at"

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
                    HStack {
                        Image(systemName: healthKit.isAuthorized ? "heart.fill" : "heart.slash")
                            .foregroundStyle(healthKit.isAuthorized ? .red : .secondary)
                        Text(healthKit.isAuthorized ? "Apple Health conectado" : "Apple Health no conectado")
                            .font(.subheadline)
                        Spacer()
                        if let last = lastSyncDate {
                            Text("Sync \(timeAgo(last))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if healthKit.isAuthorized {
                        Button {
                            Task {
                                isConnectingHealthKit = true
                                await HealthKitManager.shared.syncToBackend(days: 30, force: true)
                                isConnectingHealthKit = false
                                refreshHealthKit()
                            }
                        } label: {
                            HStack {
                                if isConnectingHealthKit || healthKit.isSyncing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text("Sincronizar HealthKit ahora")
                            }
                        }
                        .disabled(isConnectingHealthKit || healthKit.isSyncing)
                    } else {
                        Button {
                            Task {
                                isConnectingHealthKit = true
                                healthKitError = nil
                                do {
                                    try await HealthKitManager.shared.requestAuthorization()
                                    if healthKit.isAuthorized {
                                        await HealthKitManager.shared.syncToBackend(days: 7, force: true)
                                        refreshHealthKit()
                                    } else {
                                        healthKitError = "Has denegado el acceso. Activalo en Ajustes de iOS > Salud > Datos y acceso > Apps."
                                    }
                                } catch {
                                    healthKitError = "No se pudo conectar: \(error.localizedDescription)"
                                }
                                isConnectingHealthKit = false
                            }
                        } label: {
                            HStack {
                                if isConnectingHealthKit {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "heart.fill")
                                }
                                Text("Conectar Apple Health")
                            }
                        }
                        .disabled(isConnectingHealthKit)

                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Abrir Ajustes de iOS", systemImage: "gear")
                        }
                    }

                    if let err = healthKitError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    if let last = healthKit.lastError, healthKit.isAuthorized {
                        Text(last).font(.caption).foregroundStyle(.orange)
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
            .task {
                refreshHealthKit()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // El usuario pudo haber cambiado permisos en Ajustes de iOS
                refreshHealthKit()
            }
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

    private func refreshHealthKit() {
        healthKitAuthorized = HealthKitManager.shared.refreshAuthorizationStatus()
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    private func timeAgo(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "ahora" }
        if elapsed < 3600 { return "hace \(Int(elapsed/60))m" }
        if elapsed < 86400 { return "hace \(Int(elapsed/3600))h" }
        return "hace \(Int(elapsed/86400))d"
    }
}