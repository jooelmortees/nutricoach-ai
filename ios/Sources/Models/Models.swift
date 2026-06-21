// ============================================================
// Models
// ============================================================

import Foundation

struct Profile: Codable, Identifiable {
    let id: UUID
    var fullName: String?
    var birthDate: String?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    var targetWeightKg: Double?
    var activityLevel: String?
    var goal: String?
    var dailyKcalTarget: Int?
    var dailyProteinG: Int?
    var dailyCarbsG: Int?
    var dailyFatG: Int?
    var dietaryStyle: [String]?
    var allergens: [String]?
    var restrictions: [String]?
    var medicalConditions: [String]?
    var medications: [String]?
    var householdContext: String?
    var cookingSkill: String?
    var budgetEurPerWeek: Double?
    var locale: String?
    var timezone: String?
    var onboardedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case birthDate = "birth_date"
        case sex
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case targetWeightKg = "target_weight_kg"
        case activityLevel = "activity_level"
        case goal
        case dailyKcalTarget = "daily_kcal_target"
        case dailyProteinG = "daily_protein_g"
        case dailyCarbsG = "daily_carbs_g"
        case dailyFatG = "daily_fat_target"
        case dietaryStyle = "dietary_style"
        case allergens
        case restrictions
        case medicalConditions = "medical_conditions"
        case medications
        case householdContext = "household_context"
        case cookingSkill = "cooking_skill"
        case budgetEurPerWeek = "budget_eur_per_week"
        case locale
        case timezone
        case onboardedAt = "onboarded_at"
    }
}

struct Conversation: Codable, Identifiable {
    let id: UUID
    var title: String?
    var startedAt: String?
    var lastMessageAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case startedAt = "started_at"
        case lastMessageAt = "last_message_at"
    }
}

struct Message: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let role: String
    var content: String?
    var thinking: String?
    var attachments: [String]?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role, content, thinking, attachments
        case createdAt = "created_at"
    }
}

struct Meal: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    var loggedAt: String
    var mealType: String?
    var name: String?
    var notes: String?
    var photoUrls: [String]?
    var videoUrl: String?
    var totalKcal: Double?
    var totalProteinG: Double?
    var totalCarbsG: Double?
    var totalFatG: Double?
    var totalFiberG: Double?
    var aiAnalysis: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case loggedAt = "logged_at"
        case mealType = "meal_type"
        case name, notes
        case photoUrls = "photo_urls"
        case videoUrl = "video_url"
        case totalKcal = "total_kcal"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
        case totalFiberG = "total_fiber_g"
        case aiAnalysis = "ai_analysis"
    }
}

struct HealthMetric: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let type: String
    let value: Double
    let unit: String
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case type, value, unit
        case recordedAt = "recorded_at"
    }
}

struct MemoryFact: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let category: String
    let fact: String
    let confidence: Double
    let isActive: Bool
    let createdAt: String
    let lastConfirmedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case category, fact, confidence
        case isActive = "is_active"
        case createdAt = "created_at"
        case lastConfirmedAt = "last_confirmed_at"
    }
}
