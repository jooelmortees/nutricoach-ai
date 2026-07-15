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
/// Los campos extendidos (ingredients, preparationSteps, prepTimeMinutes, etc.)
/// son opcionales para mantener compatibilidad con planes antiguos que solo
/// tienen name/kcal/macros/notes. La Edge Function generate-plan siempre los
/// rellena a partir de la version extendida del prompt.
struct PlanMeal: Codable, Identifiable, Equatable {
    var id: String { "\(type)-\(name)" }
    var type: MealType
    var name: String
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var notes: String?
    // Campos extendidos (opcionales para planes antiguos)
    var fiberG: Double?
    var ingredients: [PlanIngredient]?
    var preparation: String?
    var preparationSteps: [String]?
    var prepTimeMinutes: Int?
    var cookTimeMinutes: Int?
    var servings: Int?
    var difficulty: PlanMealDifficulty?
    var tips: String?
    var allergens: [String]?

    enum CodingKeys: String, CodingKey {
        case type, name, kcal, notes
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case ingredients, preparation
        case preparationSteps = "preparation_steps"
        case prepTimeMinutes = "prep_time_min"
        case cookTimeMinutes = "cook_time_min"
        case servings, difficulty, tips, allergens
    }

    /// Tiempo total en minutos (prep + coccion). Nil si no hay datos.
    var totalTimeMinutes: Int? {
        let prep = prepTimeMinutes ?? 0
        let cook = cookTimeMinutes ?? 0
        guard prep > 0 || cook > 0 else { return nil }
        return prep + cook
    }

    /// Pasos estructurados de planes nuevos, con fallback para planes antiguos.
    var recipeSteps: [String] {
        if let preparationSteps {
            let steps = preparationSteps
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !steps.isEmpty { return steps }
        }
        guard let preparation, !preparation.isEmpty else { return [] }
        let lines = preparation
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.map {
            $0.replacingOccurrences(
                of: #"^(?:Paso\s+)?\d+[\.\)\-:]\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    var hasDetailedRecipe: Bool {
        guard let ingredients, !ingredients.isEmpty else { return false }
        return !recipeSteps.isEmpty
    }
}

/// Ingrediente de una comida del plan.
struct PlanIngredient: Codable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var name: String
    var quantity: Double?
    var unit: String?
}

/// Dificultad de preparacion de una comida del plan.
/// El init custom normaliza tildes y mayusculas para tolerar
/// variaciones que Gemini pueda devolver (ej: "Facil", "Fácil", "MEDIA").
enum PlanMealDifficulty: String, Codable, CaseIterable {
    case facil
    case media
    case alta

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "á", with: "a")
            .replacingOccurrences(of: "é", with: "e")
            .replacingOccurrences(of: "í", with: "i")
            .replacingOccurrences(of: "ó", with: "o")
            .replacingOccurrences(of: "ú", with: "u")
        switch normalized {
        case "facil": self = .facil
        case "media", "medio": self = .media
        case "alta", "alto": self = .alta
        default: self = .facil
        }
    }

    var label: String {
        switch self {
        case .facil: return "Facil"
        case .media: return "Media"
        case .alta: return "Alta"
        }
    }

    var icon: String {
        switch self {
        case .facil: return "1.circle.fill"
        case .media: return "2.circle.fill"
        case .alta: return "3.circle.fill"
        }
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
