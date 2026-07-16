import WidgetKit

struct DailyTrackingEntry: TimelineEntry {
    let date: Date
    let snapshot: DailyTrackingSnapshot
}

struct DailyTrackingProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyTrackingEntry {
        DailyTrackingEntry(
            date: Date(),
            snapshot: DailyTrackingSnapshot(
                userId: UUID(),
                date: Date(),
                updatedAt: Date(),
                timeZoneIdentifier: "Europe/Madrid",
                totals: DailyMacroTotals(
                    kcal: 1260,
                    protein: 92,
                    carbs: 138,
                    fat: 42
                ),
                kcalTarget: 2200,
                proteinTarget: 150,
                carbsTarget: 240,
                fatTarget: 70,
                waterMl: 1250,
                waterTargetMl: 2000
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (DailyTrackingEntry) -> Void
    ) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<DailyTrackingEntry>) -> Void
    ) {
        let currentEntry = entry()
        let calendar = currentEntry.snapshot.calendar
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: Date())
        ) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [currentEntry], policy: .after(nextMidnight)))
    }

    private func entry() -> DailyTrackingEntry {
        var snapshot = WidgetSnapshotStore.load() ?? .empty
        let currentUserId = SupabaseService.shared.client.auth.currentUser?.id
        guard let currentUserId, snapshot.userId == currentUserId else {
            return DailyTrackingEntry(date: Date(), snapshot: .empty)
        }
        if !snapshot.isForToday {
            snapshot.date = Date()
            snapshot.updatedAt = Date()
            snapshot.totals = DailyMacroTotals()
            snapshot.waterMl = 0
        }
        return DailyTrackingEntry(date: Date(), snapshot: snapshot)
    }
}

enum WidgetLink {
    static let macros = URL(string: "nutricoach://macros")!
    static let newMeal = URL(string: "nutricoach://meal/new")!
}
