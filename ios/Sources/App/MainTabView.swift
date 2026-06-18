// ============================================================
// MainTabView - tab bar principal
// ============================================================

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .chat

    enum Tab: String, Hashable {
        case chat, camera, dashboard, plans, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chat)

            CameraView()
                .tabItem { Label("Cámara", systemImage: "camera.fill") }
                .tag(Tab.camera)

            DashboardView()
                .tabItem { Label("Hoy", systemImage: "chart.bar.fill") }
                .tag(Tab.dashboard)

            PlansView()
                .tabItem { Label("Planes", systemImage: "list.bullet.rectangle.fill") }
                .tag(Tab.plans)

            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}
