// ============================================================
// AppState - estado global de la app
// ============================================================

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    enum Route: Equatable {
        case macros
        case newMeal
    }

    @Published var currentConversationId: String?
    @Published var hasUnreadNudges: Bool = false
    @Published var isOnline: Bool = true
    @Published var pendingRoute: Route?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Suscribirse a cambios de red (NWPathMonitor)
        NetworkMonitor.shared.start()
        NetworkMonitor.shared.$isOnline
            .receive(on: DispatchQueue.main)
            .assign(to: \.isOnline, on: self)
            .store(in: &cancellables)
    }

    func handle(url: URL) {
        guard url.scheme == "nutricoach" else { return }
        switch (url.host, url.path) {
        case ("meal", "/new"):
            pendingRoute = .newMeal
        case ("macros", _):
            pendingRoute = .macros
        default:
            break
        }
    }

    func consume(route: Route) {
        if pendingRoute == route {
            pendingRoute = nil
        }
    }
}
