// ============================================================
// PlansViewModel - logica de la pestana Planes
// ============================================================

import Foundation
import SwiftUI
import Supabase

@MainActor
final class PlansViewModel: ObservableObject {
    @Published var activePlan: MealPlan?
    @Published var otherPlans: [MealPlan] = []
    @Published var isLoading: Bool = false
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await fetchPlans()
        } catch {
            errorMessage = "Error cargando planes: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        await load()
    }

    /// Genera un plan nuevo llamando a la Edge Function generate-plan.
    func generatePlan(type: PlanType, notes: String?) async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let token = try await SupabaseService.shared.client.auth.session.accessToken
            var req = URLRequest(url: Config.generatePlanURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

            var body: [String: Any] = ["type": type.rawValue]
            if let notes, !notes.isEmpty {
                body["notes"] = notes
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "?"
                errorMessage = "Error generando plan (HTTP \(statusCode)): \(bodyStr)"
                return
            }

            // Recargar planes para mostrar el nuevo
            try await fetchPlans()
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    /// Activa un plan (pone status=active, archiva el anterior activo).
    func activatePlan(_ plan: MealPlan) async {
        do {
            let supabase = SupabaseService.shared.client
            let planId = plan.id.uuidString

            // Archivar el plan activo actual (si hay)
            if let active = activePlan, active.id != plan.id {
                _ = try? await supabase
                    .from("meal_plans")
                    .update(["status": "archived", "updated_at": ISO8601DateFormatter().string(from: Date())])
                    .eq("id", value: active.id.uuidString)
                    .execute()
            }

            // Activar el plan seleccionado
            try await supabase
                .from("meal_plans")
                .update(["status": "active", "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: planId)
                .execute()

            await fetchPlans()
        } catch {
            errorMessage = "Error activando plan: \(error.localizedDescription)"
        }
    }

    /// Archiva un plan.
    func archivePlan(_ plan: MealPlan) async {
        do {
            let supabase = SupabaseService.shared.client
            try await supabase
                .from("meal_plans")
                .update(["status": "archived", "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: plan.id.uuidString)
                .execute()
            await fetchPlans()
        } catch {
            errorMessage = "Error archivando plan: \(error.localizedDescription)"
        }
    }

    /// Borra un plan.
    func deletePlan(_ plan: MealPlan) async {
        do {
            let supabase = SupabaseService.shared.client
            try await supabase
                .from("meal_plans")
                .delete()
                .eq("id", value: plan.id.uuidString)
                .execute()
            await fetchPlans()
        } catch {
            errorMessage = "Error borrando plan: \(error.localizedDescription)"
        }
    }

    // MARK: - Privados

    private func fetchPlans() async throws {
        let supabase = SupabaseService.shared.client

        // Decodificamos plan como PlanContent directamente: supabase-swift
        // usa JSONDecoder internamente, y jsonb se devuelve como objeto JSON
        // nativo (no como string). Si lo declararamos como String, fallaria.
        struct PlanRow: Decodable {
            let id: UUID
            let user_id: UUID
            let week_start: String
            let plan: PlanContent
            let generated_by: String?
            let status: String
            let notes: String?
            let created_at: String
            let updated_at: String?
        }

        let rows: [PlanRow] = try await supabase
            .from("meal_plans")
            .select("id,user_id,week_start,plan,generated_by,status,notes,created_at,updated_at")
            .order("created_at", ascending: false)
            .execute()
            .value

        let plans: [MealPlan] = rows.map { row in
            MealPlan(
                id: row.id,
                userId: row.user_id,
                weekStart: row.week_start,
                plan: row.plan,
                generatedBy: row.generated_by,
                status: PlanStatus(rawValue: row.status) ?? .draft,
                notes: row.notes,
                createdAt: row.created_at,
                updatedAt: row.updated_at
            )
        }

        // Separar activo del resto
        if let active = plans.first(where: { $0.status == .active }) {
            activePlan = active
            otherPlans = plans.filter { $0.id != active.id }
        } else {
            activePlan = nil
            otherPlans = plans
        }
    }
}