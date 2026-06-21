// ============================================================
// App principal - entry point
// ============================================================

import SwiftUI
import Supabase

@main
struct NutriCoachApp: App {
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
                .task {
                    await authManager.restoreSession()
                }
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
                if let profile = auth.profile, profile.onboardedAt == nil {
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
