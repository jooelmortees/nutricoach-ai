// ============================================================
// MacrosViewModel - logica de la pestana de macros
// ============================================================

import Foundation
import SwiftUI

struct LoggedMeal: Identifiable, Decodable {
    let id: UUID
    let name: String
    let meal_type: String?
    let total_kcal: Double?
    let total_protein_g: Double?
    let total_carbs_g: Double?
    let total_fat_g: Double?
    let total_fiber_g: Double?
    let source: String?
    let logged_at: String
    let created_at: String

    var loggedAt: Date {
        DateParsing.parse(logged_at) ?? Date()
    }
}

@MainActor
final class MacrosViewModel: ObservableObject {
    @Published var meals: [LoggedMeal] = []
    @Published var waterLogs: [WaterLog] = []
    @Published var profile: Profile?
    @Published var isLoading = false
    @Published var isWaterMutating = false
    @Published var errorMessage: String?

    @Published var selectedDate = Date()
    @Published var displayedMonth = Date()
    @Published var monthMeals: [LoggedMeal] = []
    @Published var isMonthLoading = false

    private var activeDayRequestId: UUID?
    private var activeMonthRequestId: UUID?
    private var followsCurrentDay = true

    struct Totals {
        var kcal: Double = 0
        var protein: Double = 0
        var carbs: Double = 0
        var fat: Double = 0
    }

    var totals: Totals {
        meals.reduce(Totals()) { acc, meal in
            Totals(
                kcal: acc.kcal + (meal.total_kcal ?? 0),
                protein: acc.protein + (meal.total_protein_g ?? 0),
                carbs: acc.carbs + (meal.total_carbs_g ?? 0),
                fat: acc.fat + (meal.total_fat_g ?? 0)
            )
        }
    }

    var waterTotalMl: Int {
        waterLogs.reduce(0) { $0 + $1.amountMl }
    }

    var calendar: Calendar {
        trackingCalendar()
    }

    func load(userId: String?) async {
        guard let userId, !isWaterMutating else { return }
        let requestId = UUID()
        let requestedDate = selectedDate
        activeDayRequestId = requestId
        isLoading = true
        errorMessage = nil
        do {
            let loadedProfile = try await fetchProfile(userId: userId)
            let loadedMeals = try await fetchMeals(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
            let loadedWaterLogs = try await fetchWaterLogs(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
            guard activeDayRequestId == requestId else { return }
            profile = loadedProfile
            meals = loadedMeals
            waterLogs = loadedWaterLogs
            await fetchMonthMeals(userId: userId)
            guard activeDayRequestId == requestId else { return }
            await refreshWidgetSnapshotIfNeeded(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
        } catch {
            if activeDayRequestId == requestId {
                errorMessage = error.localizedDescription
            }
        }
        if activeDayRequestId == requestId {
            isLoading = false
        }
    }

    func refresh(userId: String? = nil) async {
        await load(userId: userId)
    }

    func selectDate(_ date: Date, userId: String?) async {
        guard !isWaterMutating else { return }
        let calendar = trackingCalendar()
        selectedDate = calendar.startOfDay(for: date)
        followsCurrentDay = calendar.isDate(selectedDate, inSameDayAs: Date())
        guard let userId else { return }
        let requestId = UUID()
        let requestedDate = selectedDate
        activeDayRequestId = requestId
        isLoading = true
        errorMessage = nil
        do {
            let loadedProfile: Profile
            if let profile, profile.id.uuidString.lowercased() == userId.lowercased() {
                loadedProfile = profile
            } else {
                loadedProfile = try await fetchProfile(userId: userId)
            }
            let loadedMeals = try await fetchMeals(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
            let loadedWaterLogs = try await fetchWaterLogs(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
            guard activeDayRequestId == requestId else { return }
            profile = loadedProfile
            meals = loadedMeals
            waterLogs = loadedWaterLogs
            await refreshWidgetSnapshotIfNeeded(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: loadedProfile.timezone
            )
        } catch {
            if activeDayRequestId == requestId {
                errorMessage = error.localizedDescription
            }
        }
        if activeDayRequestId == requestId {
            isLoading = false
        }
    }

    func changeMonth(by value: Int, userId: String?) async {
        let calendar = trackingCalendar()
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = calendar.startOfDay(for: newMonth)
            await fetchMonthMeals(userId: userId)
        }
    }

    func handleDayChange(userId: String?) async {
        guard followsCurrentDay, !isWaterMutating else { return }
        let calendar = trackingCalendar()
        guard !calendar.isDate(selectedDate, inSameDayAs: Date()) else { return }
        selectedDate = Date()
        displayedMonth = Date()
        await load(userId: userId)
    }

    private func fetchMeals(
        userId: String,
        for date: Date,
        timeZoneIdentifier: String?
    ) async throws -> [LoggedMeal] {
        struct Row: Decodable {
            let id: UUID
            let name: String?
            let meal_type: String?
            let total_kcal: Double?
            let total_protein_g: Double?
            let total_carbs_g: Double?
            let total_fat_g: Double?
            let total_fiber_g: Double?
            let source: String?
            let logged_at: String
            let created_at: String
        }
        let calendar = trackingCalendar(timeZoneIdentifier: timeZoneIdentifier)
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw DailyTrackingError.invalidDate
        }
        let rows: [Row] = try await SupabaseService.shared.client
            .from("meals")
            .select("id,name,meal_type,total_kcal,total_protein_g,total_carbs_g,total_fat_g,total_fiber_g,source,logged_at,created_at")
            .eq("user_id", value: userId)
            .gte("logged_at", value: start.ISO8601Format())
            .lt("logged_at", value: end.ISO8601Format())
            .order("logged_at", ascending: true)
            .execute()
            .value
        return rows.map { LoggedMeal(
            id: $0.id,
            name: $0.name ?? "Comida sin nombre",
            meal_type: $0.meal_type,
            total_kcal: $0.total_kcal,
            total_protein_g: $0.total_protein_g,
            total_carbs_g: $0.total_carbs_g,
            total_fat_g: $0.total_fat_g,
            total_fiber_g: $0.total_fiber_g,
            source: $0.source,
            logged_at: $0.logged_at,
            created_at: $0.created_at
        ) }
    }

    private func fetchProfile(userId: String) async throws -> Profile {
        let response: Profile = try await SupabaseService.shared.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        return response
    }

    private func fetchWaterLogs(
        userId: String,
        for date: Date,
        timeZoneIdentifier: String?
    ) async throws -> [WaterLog] {
        guard let userUUID = UUID(uuidString: userId) else {
            throw DailyTrackingError.invalidUser
        }
        return try await DailyTrackingService.shared.fetchWaterLogs(
            userId: userUUID,
            for: date,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func fetchMonthMeals(userId: String?) async {
        guard let userId else { return }
        let requestId = UUID()
        let requestedMonth = displayedMonth
        activeMonthRequestId = requestId
        isMonthLoading = true
        defer {
            if activeMonthRequestId == requestId {
                isMonthLoading = false
            }
        }
        do {
            let calendar = trackingCalendar()
            guard let firstOfMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: requestedMonth)
            ), let firstOfNextMonth = calendar.date(
                byAdding: .month,
                value: 1,
                to: firstOfMonth
            ) else {
                throw DailyTrackingError.invalidDate
            }
            let startISO = firstOfMonth.ISO8601Format()
            let endISO = firstOfNextMonth.ISO8601Format()

            struct Row: Decodable {
                let id: UUID
                let name: String?
                let total_kcal: Double?
                let logged_at: String
            }
            let rows: [Row] = try await SupabaseService.shared.client
                .from("meals")
                .select("id,name,total_kcal,logged_at")
                .eq("user_id", value: userId)
                .gte("logged_at", value: startISO)
                .lt("logged_at", value: endISO)
                .order("logged_at", ascending: true)
                .execute()
                .value
            guard activeMonthRequestId == requestId else { return }
            monthMeals = rows.map { LoggedMeal(
                id: $0.id,
                name: $0.name ?? "Comida sin nombre",
                meal_type: nil,
                total_kcal: $0.total_kcal,
                total_protein_g: nil,
                total_carbs_g: nil,
                total_fat_g: nil,
                total_fiber_g: nil,
                source: nil,
                logged_at: $0.logged_at,
                created_at: ""
            ) }
        } catch {
            if activeMonthRequestId == requestId {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteMeal(_ meal: LoggedMeal, userId: String?) async {
        guard let userId else { return }
        do {
            try await SupabaseService.shared.client
                .from("meals")
                .delete()
                .eq("id", value: meal.id.uuidString)
                .eq("user_id", value: userId)
                .execute()
            meals.removeAll { $0.id == meal.id }
            monthMeals.removeAll { $0.id == meal.id }
            await refreshWidgetSnapshotIfNeeded(
                userId: userId,
                for: selectedDate,
                timeZoneIdentifier: profile?.timezone
            )
        } catch {
            errorMessage = "Error eliminando: \(error.localizedDescription)"
        }
    }

    func updateMeal(_ meal: LoggedMeal, name: String, mealType: String, kcal: Double?, protein: Double?, carbs: Double?, fat: Double?, userId: String?) async throws {
        guard let userId else { return }
        struct UpdatePayload: Encodable {
            let name: String
            let meal_type: String
            let total_kcal: Double?
            let total_protein_g: Double?
            let total_carbs_g: Double?
            let total_fat_g: Double?
        }
        let payload = UpdatePayload(
            name: name,
            meal_type: mealType,
            total_kcal: kcal,
            total_protein_g: protein,
            total_carbs_g: carbs,
            total_fat_g: fat
        )
        try await SupabaseService.shared.client
            .from("meals")
            .update(payload)
            .eq("id", value: meal.id.uuidString)
            .eq("user_id", value: userId)
            .execute()
        if let idx = meals.firstIndex(where: { $0.id == meal.id }) {
            meals[idx] = LoggedMeal(
                id: meal.id,
                name: name,
                meal_type: mealType,
                total_kcal: kcal,
                total_protein_g: protein,
                total_carbs_g: carbs,
                total_fat_g: fat,
                total_fiber_g: meal.total_fiber_g,
                source: meal.source,
                logged_at: meal.logged_at,
                created_at: meal.created_at
            )
        }
        if let idx = monthMeals.firstIndex(where: { $0.id == meal.id }) {
            monthMeals[idx] = LoggedMeal(
                id: meal.id,
                name: name,
                meal_type: nil,
                total_kcal: kcal,
                total_protein_g: nil,
                total_carbs_g: nil,
                total_fat_g: nil,
                total_fiber_g: nil,
                source: nil,
                logged_at: meal.logged_at,
                created_at: ""
            )
        }
        await refreshWidgetSnapshotIfNeeded(
            userId: userId,
            for: selectedDate,
            timeZoneIdentifier: profile?.timezone
        )
    }

    func addMeal(
        name: String,
        mealType: String,
        kcal: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        userId: String?
    ) async throws {
        guard let userId, let userUUID = UUID(uuidString: userId) else {
            throw DailyTrackingError.invalidUser
        }
        let loggedAt = Date()
        try await DailyTrackingService.shared.logManualMeal(
            userId: userUUID,
            name: name,
            mealType: mealType,
            kcal: kcal,
            protein: protein,
            carbs: carbs,
            fat: fat,
            loggedAt: loggedAt
        )
        selectedDate = trackingCalendar().startOfDay(for: loggedAt)
        followsCurrentDay = true
        await load(userId: userId)
    }

    func addWater(amountMl: Int, userId: String?) async throws {
        guard let userId, let userUUID = UUID(uuidString: userId) else {
            throw DailyTrackingError.invalidUser
        }
        guard !isWaterMutating else { return }
        isWaterMutating = true
        defer { isWaterMutating = false }
        let calendar = trackingCalendar()
        let didAdvanceCurrentDay = followsCurrentDay
            && !calendar.isDate(selectedDate, inSameDayAs: Date())
        if didAdvanceCurrentDay {
            selectedDate = Date()
            displayedMonth = Date()
        }
        let requestedDate = selectedDate
        let requestId = UUID()
        activeDayRequestId = requestId
        isLoading = false
        try await DailyTrackingService.shared.logWater(
            amountMl: amountMl,
            source: .app,
            loggedAt: followsCurrentDay ? Date() : selectedDateWithCurrentTime,
            userId: userUUID
        )
        if didAdvanceCurrentDay {
            isWaterMutating = false
            await load(userId: userId)
            return
        }
        do {
            let loadedWaterLogs = try await fetchWaterLogs(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: profile?.timezone
            )
            guard activeDayRequestId == requestId,
                  trackingCalendar().isDate(selectedDate, inSameDayAs: requestedDate) else {
                return
            }
            waterLogs = loadedWaterLogs
        } catch {
            AppLogger.warning("Agua registrada, pero no se pudo recargar: \(error.localizedDescription)")
        }
    }

    func deleteLatestWater(userId: String?) async throws {
        guard let waterLog = waterLogs.last,
              let userId,
              let userUUID = UUID(uuidString: userId) else {
            return
        }
        guard !isWaterMutating else { return }
        isWaterMutating = true
        defer { isWaterMutating = false }
        let requestedDate = selectedDate
        let requestId = UUID()
        activeDayRequestId = requestId
        isLoading = false
        try await DailyTrackingService.shared.deleteWaterLog(waterLog, userId: userUUID)
        do {
            let loadedWaterLogs = try await fetchWaterLogs(
                userId: userId,
                for: requestedDate,
                timeZoneIdentifier: profile?.timezone
            )
            guard activeDayRequestId == requestId,
                  trackingCalendar().isDate(selectedDate, inSameDayAs: requestedDate) else {
                return
            }
            waterLogs = loadedWaterLogs
        } catch {
            AppLogger.warning("Agua borrada, pero no se pudo recargar: \(error.localizedDescription)")
        }
    }

    private var selectedDateWithCurrentTime: Date {
        let calendar = trackingCalendar()
        let time = calendar.dateComponents([.hour, .minute, .second], from: Date())
        var selected = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        selected.hour = time.hour
        selected.minute = time.minute
        selected.second = time.second
        return calendar.date(from: selected) ?? selectedDate
    }

    private func refreshWidgetSnapshotIfNeeded(
        userId: String,
        for date: Date,
        timeZoneIdentifier: String?
    ) async {
        let calendar = trackingCalendar(timeZoneIdentifier: timeZoneIdentifier)
        guard calendar.isDate(date, inSameDayAs: Date()),
              let userUUID = UUID(uuidString: userId) else {
            return
        }
        do {
            try await DailyTrackingService.shared.refreshWidgetSnapshot(userId: userUUID)
        } catch {
            AppLogger.warning("No se pudo refrescar el widget: \(error.localizedDescription)")
        }
    }

    private func trackingCalendar(timeZoneIdentifier: String? = nil) -> Calendar {
        var calendar = Calendar.current
        let identifier = timeZoneIdentifier ?? profile?.timezone
        if let identifier, let timeZone = TimeZone(identifier: identifier) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    enum DayCompliance: Equatable {
        case noData
        case under(Double)
        case onTrack
        case over(Double)

        var color: Color {
            switch self {
            case .noData: return Color(.tertiarySystemFill)
            case .under(let pct): return pct < 0.5 ? Color.orange.opacity(0.6) : Color.yellow.opacity(0.7)
            case .onTrack: return Color.green
            case .over(let pct): return pct > 1.3 ? Color.red.opacity(0.8) : Color.orange.opacity(0.8)
            }
        }

        var label: String {
            switch self {
            case .noData: return "Sin datos"
            case .under: return "Por debajo"
            case .onTrack: return "En objetivo"
            case .over: return "Por encima"
            }
        }
    }

    func compliance(for day: Date) -> DayCompliance {
        let calendar = trackingCalendar()
        let target = profile?.dailyKcalTarget ?? 0
        guard target > 0 else { return .noData }
        let dayStart = calendar.startOfDay(for: day)
        let dayMeals = monthMeals.filter {
            calendar.isDate($0.loggedAt, inSameDayAs: dayStart)
        }
        guard !dayMeals.isEmpty else { return .noData }
        let kcal = dayMeals.reduce(0.0) { $0 + ($1.total_kcal ?? 0) }
        let ratio = kcal / Double(target)
        if ratio >= 0.85 && ratio <= 1.15 {
            return .onTrack
        } else if ratio < 0.85 {
            return .under(ratio)
        } else {
            return .over(ratio)
        }
    }

    var isToday: Bool {
        trackingCalendar().isDate(selectedDate, inSameDayAs: Date())
    }
}
