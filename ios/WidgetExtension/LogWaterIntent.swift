import AppIntents

struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar agua"
    static var description = IntentDescription(
        "Registra agua en el seguimiento diario de NutriCoach."
    )
    static var isDiscoverable = false

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
        guard let expectedUserId = UUID(uuidString: userId),
              SupabaseService.shared.client.auth.currentUser?.id == expectedUserId,
              WidgetSnapshotStore.load()?.userId == expectedUserId else {
            throw DailyTrackingError.invalidUser
        }
        try await DailyTrackingService.shared.logWater(
            amountMl: amountMl,
            source: .widget,
            userId: expectedUserId
        )
        return .result()
    }
}
