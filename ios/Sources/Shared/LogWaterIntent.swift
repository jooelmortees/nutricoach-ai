import AppIntents

struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar agua"
    static var description = IntentDescription(
        "Registra agua en el seguimiento diario de NutriCoach."
    )
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Cantidad en mililitros")
    var amountMl: Int

    @Parameter(title: "Usuario")
    var userId: String

    init() {
        amountMl = 250
        userId = ""
    }

    init(amountMl: Int, userId: UUID) {
        self.amountMl = amountMl
        self.userId = userId.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard (1...5000).contains(amountMl),
              let expectedUserId = UUID(uuidString: userId),
              WidgetSnapshotStore.activeUserId == expectedUserId,
              WidgetSnapshotStore.load()?.userId == expectedUserId else {
            return .result()
        }
        do {
            let authenticatedUserId = try await SupabaseService.shared.client.auth.session.user.id
            guard authenticatedUserId == expectedUserId else {
                DailyTrackingService.shared.markWaterSyncFailed(userId: expectedUserId)
                return .result()
            }
            try await DailyTrackingService.shared.logWater(
                amountMl: amountMl,
                source: .widget,
                userId: authenticatedUserId
            )
        } catch {
            do {
                try await DailyTrackingService.shared.refreshWidgetSnapshot(
                    userId: expectedUserId
                )
            } catch {
                DailyTrackingService.shared.markWaterSyncFailed(userId: expectedUserId)
            }
        }
        return .result()
    }
}
