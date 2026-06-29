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
    @Published var profile: Profile?
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var displayedMonth: Date = Calendar.current.startOfDay(for: Date())
    @Published var monthMeals: [LoggedMeal] = []
    @Published var isMonthLoading = false

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

    func load(userId: String?) async {
        guard let userId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await fetchMeals(userId: userId)
            try await fetchProfile(userId: userId)
            await fetchMonthMeals(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(userId: String? = nil) async {
        await load(userId: userId)
    }

    func selectDate(_ date: Date, userId: String?) async {
        selectedDate = Calendar.current.startOfDay(for: date)
        guard let userId else { return }
        do {
            try await fetchMeals(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changeMonth(by value: Int, userId: String?) async {
        let calendar = Calendar.current
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = calendar.startOfDay(for: newMonth)
            await fetchMonthMeals(userId: userId)
        }
    }

    private func fetchMeals(userId: String) async throws {
        struct Row: Decodable {
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
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate).ISO8601Format()
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selectedDate))!.ISO8601Format()
        let rows: [Row] = try await SupabaseService.shared.client
            .from("meals")
            .select("id,name,meal_type,total_kcal,total_protein_g,total_carbs_g,total_fat_g,total_fiber_g,source,logged_at,created_at")
            .eq("user_id", value: userId)
            .gte("logged_at", value: dayStart)
            .lt("logged_at", value: dayEnd)
            .order("logged_at", ascending: true)
            .execute()
            .value
        meals = rows.map { LoggedMeal(
            id: $0.id,
            name: $0.name,
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

    private func fetchProfile(userId: String) async throws {
        let response: Profile = try await SupabaseService.shared.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        profile = response
    }

    func fetchMonthMeals(userId: String?) async {
        guard let userId else { return }
        isMonthLoading = true
        defer { isMonthLoading = false }
        do {
            let calendar = Calendar.current
            let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))!
            let firstOfNextMonth = calendar.date(byAdding: .month, value: 1, to: firstOfMonth)!
            let startISO = firstOfMonth.ISO8601Format()
            let endISO = firstOfNextMonth.ISO8601Format()

            struct Row: Decodable {
                let id: UUID
                let name: String
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
            monthMeals = rows.map { LoggedMeal(
                id: $0.id,
                name: $0.name,
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
            errorMessage = error.localizedDescription
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
        let calendar = Calendar.current
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
        Calendar.current.isDateInToday(selectedDate)
    }
}