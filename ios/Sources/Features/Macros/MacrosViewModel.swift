// ============================================================
// MacrosViewModel - lógica de la pestaña de macros
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(userId: String? = nil) async {
        await load(userId: userId)
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
        let today = Calendar.current.startOfDay(for: Date()).ISO8601Format()
        let rows: [Row] = try await SupabaseService.shared.client
            .from("meals")
            .select("id,name,meal_type,total_kcal,total_protein_g,total_carbs_g,total_fat_g,total_fiber_g,source,logged_at,created_at")
            .eq("user_id", value: userId)
            .gte("logged_at", value: today)
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
}