// ============================================================
// Plans - modelos para planes de dieta
// ============================================================

import Foundation

/// Plan de dieta guardado en la tabla `meal_plans`.
/// El campo `plan` (jsonb) se decodifica a `PlanContent`.
struct MealPlan: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let weekStart: String
    var plan: PlanContent
    var generatedBy: String?
    var status: PlanStatus
    var notes: String?
    let createdAt: String
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case weekStart = "week_start"
        case plan, status, notes
        case generatedBy = "generated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Estado del plan (enum de Postgres plan_status_t)
enum PlanStatus: String, Codable, CaseIterable {
    case draft
    case active
    case completed
    case archived
}

/// Contenido del plan (campo jsonb `plan` de meal_plans).
/// Generado por el agente o por la Edge Function generate-plan.
struct PlanContent: Codable, Equatable {
    var type: PlanType
    var title: String
    var summary: String
    var targetKcal: Int?
    var targetProteinG: Int?
    var targetCarbsG: Int?
    var targetFatG: Int?
    var days: [PlanDay]

    enum CodingKeys: String, CodingKey {
        case type, title, summary, days
        case targetKcal = "target_kcal"
        case targetProteinG = "target_protein_g"
        case targetCarbsG = "target_carbs_g"
        case targetFatG = "target_fat_g"
    }
}

/// Tipo de plan: semanal (7 dias) o diario (1 dia).
enum PlanType: String, Codable {
    case weekly
    case daily
}

/// Un dia del plan.
struct PlanDay: Codable, Identifiable, Equatable {
    var id: String { day }
    var day: String
    var meals: [PlanMeal]
}

/// Una comida del plan.
struct PlanMeal: Codable, Identifiable, Equatable {
    var id: String { "\(type)-\(name)" }
    var type: MealType
    var name: String
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case type, name, kcal, notes
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

/// Tipo de comida (mapea a meal_type de la tabla meals).
enum MealType: String, Codable, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snack
    case other

    var label: String {
        switch self {
        case .breakfast: return "Desayuno"
        case .lunch: return "Almuerzo"
        case .dinner: return "Cena"
        case .snack: return "Snack"
        case .other: return "Otro"
        }
    }

    var icon: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "applelogo"
        case .other: return "fork.knife"
        }
    }
}

// MARK: - Extensiones de UI para PlanStatus

extension PlanStatus {
    var label: String {
        switch self {
        case .draft: return "Borrador"
        case .active: return "Activo"
        case .completed: return "Completado"
        case .archived: return "Archivado"
        }
    }

    var color: String {
        switch self {
        case .draft: return "gray"
        case .active: return "green"
        case .completed: return "blue"
        case .archived: return "secondary"
        }
    }
}