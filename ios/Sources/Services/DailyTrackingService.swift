import Foundation
import OSLog
import Supabase
import WidgetKit

final class DailyTrackingService {
    static let shared = DailyTrackingService()

    private let client = SupabaseService.shared.client
    private let logger = Logger(
        subsystem: "com.joelmortees.nutricoach",
        category: "DailyTracking"
    )

    private init() {}

    func fetchWaterLogs(
        userId: UUID,
        for date: Date,
        timeZoneIdentifier: String?
    ) async throws -> [WaterLog] {
        let bounds = try dayBounds(
            for: date,
            timeZoneIdentifier: timeZoneIdentifier
        )
        return try await client
            .from("water_logs")
            .select()
            .eq("user_id", value: userId.uuidString)
            .gte("logged_at", value: bounds.start)
            .lt("logged_at", value: bounds.end)
            .order("logged_at", ascending: true)
            .execute()
            .value
    }

    func logWater(
        amountMl: Int,
        source: WaterLogSource,
        loggedAt: Date = Date(),
        clientEventId: String = UUID().uuidString,
        userId: UUID? = nil
    ) async throws {
        guard (1...5000).contains(amountMl) else {
            throw DailyTrackingError.invalidWaterAmount
        }

        let resolvedUserId = try await resolveUserId(userId)
        struct InsertPayload: Encodable {
            let user_id: String
            let amount_ml: Int
            let logged_at: String
            let source: String
            let client_event_id: String
        }

        let payload = InsertPayload(
            user_id: resolvedUserId.uuidString,
            amount_ml: amountMl,
            logged_at: loggedAt.ISO8601Format(),
            source: source.rawValue,
            client_event_id: clientEventId
        )
        try await client
            .from("water_logs")
            .upsert(
                payload,
                onConflict: "user_id,client_event_id",
                ignoreDuplicates: true
            )
            .execute()

        do {
            try await refreshWidgetSnapshot(userId: resolvedUserId)
        } catch {
            logger.warning("No se pudo refrescar el snapshot tras registrar agua: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteWaterLog(_ waterLog: WaterLog, userId: UUID) async throws {
        try await client
            .from("water_logs")
            .delete()
            .eq("id", value: waterLog.id.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
        do {
            try await refreshWidgetSnapshot(userId: userId)
        } catch {
            logger.warning("No se pudo refrescar el snapshot tras borrar agua: \(error.localizedDescription, privacy: .public)")
        }
    }

    func logManualMeal(
        userId: UUID,
        name: String,
        mealType: String,
        kcal: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        loggedAt: Date
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DailyTrackingError.emptyMealName
        }
        guard [kcal, protein, carbs, fat].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw DailyTrackingError.negativeMacro
        }

        struct InsertPayload: Encodable {
            let user_id: String
            let name: String
            let meal_type: String
            let total_kcal: Double?
            let total_protein_g: Double?
            let total_carbs_g: Double?
            let total_fat_g: Double?
            let logged_at: String
            let source: String
        }

        let payload = InsertPayload(
            user_id: userId.uuidString,
            name: trimmedName,
            meal_type: mealType,
            total_kcal: kcal,
            total_protein_g: protein,
            total_carbs_g: carbs,
            total_fat_g: fat,
            logged_at: loggedAt.ISO8601Format(),
            source: "manual"
        )
        try await client.from("meals").insert(payload).execute()
        do {
            try await refreshWidgetSnapshot(userId: userId)
        } catch {
            logger.warning("No se pudo refrescar el snapshot tras registrar comida: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshWidgetSnapshot(userId: UUID? = nil) async throws {
        let referenceDate = Date()
        let resolvedUserId = try await resolveUserId(userId)

        struct MacroRow: Decodable {
            let total_kcal: Double?
            let total_protein_g: Double?
            let total_carbs_g: Double?
            let total_fat_g: Double?
        }
        struct WaterRow: Decodable {
            let amount_ml: Int
        }

        let profile: Profile = try await client
            .from("profiles")
            .select()
            .eq("id", value: resolvedUserId.uuidString)
            .single()
            .execute()
            .value
        let bounds = try dayBounds(
            for: referenceDate,
            timeZoneIdentifier: profile.timezone
        )
        async let mealsRequest: [MacroRow] = client
            .from("meals")
            .select("total_kcal,total_protein_g,total_carbs_g,total_fat_g")
            .eq("user_id", value: resolvedUserId.uuidString)
            .gte("logged_at", value: bounds.start)
            .lt("logged_at", value: bounds.end)
            .execute()
            .value
        async let waterRequest: [WaterRow] = client
            .from("water_logs")
            .select("amount_ml")
            .eq("user_id", value: resolvedUserId.uuidString)
            .gte("logged_at", value: bounds.start)
            .lt("logged_at", value: bounds.end)
            .execute()
            .value

        let (meals, waterLogs) = try await (mealsRequest, waterRequest)
        let totals = meals.reduce(into: DailyMacroTotals()) { totals, meal in
            totals.kcal += meal.total_kcal ?? 0
            totals.protein += meal.total_protein_g ?? 0
            totals.carbs += meal.total_carbs_g ?? 0
            totals.fat += meal.total_fat_g ?? 0
        }
        let snapshot = makeSnapshot(
            date: referenceDate,
            updatedAt: referenceDate,
            totals: totals,
            profile: profile,
            waterMl: waterLogs.reduce(0) { $0 + $1.amount_ml }
        )
        try publish(snapshot)
    }

    func makeSnapshot(
        date: Date,
        updatedAt: Date = Date(),
        totals: DailyMacroTotals,
        profile: Profile,
        waterMl: Int
    ) -> DailyTrackingSnapshot {
        DailyTrackingSnapshot(
            userId: profile.id,
            date: date,
            updatedAt: updatedAt,
            timeZoneIdentifier: profile.timezone,
            totals: totals,
            kcalTarget: profile.dailyKcalTarget,
            proteinTarget: profile.dailyProteinG,
            carbsTarget: profile.dailyCarbsG,
            fatTarget: profile.dailyFatG,
            waterMl: waterMl,
            waterTargetMl: profile.dailyWaterTargetMl ?? 2000
        )
    }

    func publish(_ snapshot: DailyTrackingSnapshot) throws {
        guard snapshot.isForToday else { return }
        if try WidgetSnapshotStore.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func clearWidgetSnapshot() {
        WidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func resolveUserId(_ userId: UUID?) async throws -> UUID {
        if let userId {
            return userId
        }
        return try await client.auth.session.user.id
    }

    private func dayBounds(
        for date: Date,
        timeZoneIdentifier: String?
    ) throws -> (start: String, end: String) {
        var calendar = Calendar.current
        if let timeZoneIdentifier,
           let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw DailyTrackingError.invalidDate
        }
        return (start.ISO8601Format(), end.ISO8601Format())
    }
}

enum DailyTrackingError: LocalizedError {
    case emptyMealName
    case invalidDate
    case invalidUser
    case invalidWaterAmount
    case negativeMacro

    var errorDescription: String? {
        switch self {
        case .emptyMealName:
            return "El nombre de la comida no puede estar vacio"
        case .invalidDate:
            return "No se pudo calcular el dia seleccionado"
        case .invalidUser:
            return "No hay una sesion de usuario valida"
        case .invalidWaterAmount:
            return "La cantidad de agua debe estar entre 1 y 5000 ml"
        case .negativeMacro:
            return "Las macros no pueden ser negativas"
        }
    }
}
