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
                if let authError = auth.authError {
                    SessionRecoveryView(message: authError)
                } else if auth.profile == nil || auth.profile?.onboardedAt == nil {
                    OnboardingView()
                } else {
                    MainTabView()
                }
            }
        }
    }
}

private struct SessionRecoveryView: View {
    @EnvironmentObject private var auth: AuthManager
    let message: String
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("No se pudo cargar tu cuenta")
                .font(.title2.bold())
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    isRetrying = true
                    await auth.restoreSession()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView()
                } else {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)

            Button("Cerrar sesión", role: .destructive) {
                Task { await auth.signOut() }
            }
            .disabled(isRetrying)
        }
        .padding(32)
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
