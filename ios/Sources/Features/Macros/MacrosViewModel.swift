// ============================================================
// MacrosViewModel - lógica de la pestaña de macros
// ============================================================

import Foundation
import SwiftUI

struct LoggedMeal: Identifiable, Decodable {
    let id: UUID
    let description: String
    let meal_type: String?
    let kcal: Double?
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let confidence: Double?
    let source: String?
    let consumed_at: String
    let created_at: String

    var consumedAt: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: consumed_at) ?? Date()
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
                kcal: acc.kcal + (meal.kcal ?? 0),
                protein: acc.protein + (meal.protein_g ?? 0),
                carbs: acc.carbs + (meal.carbs_g ?? 0),
                fat: acc.fat + (meal.fat_g ?? 0)
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
            let description: String
            let meal_type: String?
            let kcal: Double?
            let protein_g: Double?
            let carbs_g: Double?
            let fat_g: Double?
            let confidence: Double?
            let source: String?
            let consumed_at: String
            let created_at: String
        }
        let today = Calendar.current.startOfDay(for: Date()).ISO8601Format()
        let rows: [Row] = try await SupabaseService.shared.client
            .from("meals")
            .select("id,description,meal_type,kcal,protein_g,carbs_g,fat_g,confidence,source,consumed_at,created_at")
            .eq("user_id", value: userId)
            .gte("consumed_at", value: today)
            .order("consumed_at", ascending: true)
            .execute()
            .value
        meals = rows.map { LoggedMeal(
            id: $0.id,
            description: $0.description,
            meal_type: $0.meal_type,
            kcal: $0.kcal,
            protein_g: $0.protein_g,
            carbs_g: $0.carbs_g,
            fat_g: $0.fat_g,
            confidence: $0.confidence,
            source: $0.source,
            consumed_at: $0.consumed_at,
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