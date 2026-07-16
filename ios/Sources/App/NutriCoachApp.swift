// ============================================================
// App principal - entry point
// ============================================================

import SwiftUI
import Supabase

@main
struct NutriCoachApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authManager = AuthManager()
    @StateObject private var appState = AppState()

    init() {
        // Configurar logging
        AppLogger.info("NutriCoach arrancando")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(appState)
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .task {
                    await authManager.restoreSession()
                    await refreshWidgetSnapshot()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await refreshWidgetSnapshot() }
                }
        }
    }

    private func refreshWidgetSnapshot() async {
        guard authManager.profile != nil else { return }
        do {
            try await DailyTrackingService.shared.refreshWidgetSnapshot()
        } catch {
            AppLogger.warning("No se pudo actualizar el widget: \(error.localizedDescription)")
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                SplashView()
            case .signedOut:
                AuthView()
            case .signedIn:
                // Si no hay perfil o no ha completado onboarding, mostrar onboarding.
                // profile nil significa que la fila no existe en BD (trigger fallo o
                // usuario creado antes de la migracion 0006).
                if auth.profile == nil || auth.profile?.onboardedAt == nil {
                    OnboardingView()
                } else {
                    MainTabView()
                }
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green.gradient)
            Text("NutriCoach")
                .font(.largeTitle)
                .bold()
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
