// ============================================================
// AppState - estado global de la app
// ============================================================

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var currentConversationId: String?
    @Published var hasUnreadNudges: Bool = false
    @Published var isOnline: Bool = true

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Suscribirse a cambios de red (NWPathMonitor)
        NetworkMonitor.shared.start()
        NetworkMonitor.shared.$isOnline
            .receive(on: DispatchQueue.main)
            .assign(to: \.isOnline, on: self)
            .store(in: &cancellables)
    }
}
