// ============================================================
// MainTabView - tab bar principal
// ============================================================

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .chat

    enum Tab: String, Hashable {
        case chat, macros, dashboard, plans, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chat)

            MacrosView()
                .tabItem { Label("Macros", systemImage: "chart.pie.fill") }
                .tag(Tab.macros)

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
        .onAppear { selectPendingRoute(appState.pendingRoute) }
        .onChange(of: appState.pendingRoute) { _, route in
            selectPendingRoute(route)
        }
    }

    private func selectPendingRoute(_ route: AppState.Route?) {
        switch route {
        case .some(.macros), .some(.newMeal):
            selectedTab = .macros
        case .none:
            break
        }
    }
}
