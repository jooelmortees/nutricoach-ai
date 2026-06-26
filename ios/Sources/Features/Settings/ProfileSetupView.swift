// ============================================================
// ProfileSetupView - edicion del perfil del usuario
// ============================================================

import SwiftUI
import Supabase

struct ProfileSetupView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var fullName: String = ""
    @State private var ageString: String = ""
    @State private var sex: String = "male"
    @State private var heightString: String = ""
    @State private var weightString: String = ""
    @State private var targetWeightString: String = ""
    @State private var activityLevel: String = "moderately_active"
    @State private var goal: String = "maintain"
    @State private var dietaryStyle: String = ""
    @State private var allergens: String = ""
    @State private var restrictions: String = ""
    @State private var medicalConditions: String = ""
    @State private var householdContext: String = ""
    @State private var cookingSkill: String = "intermediate"
    @State private var budgetString: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Básicos") {
                    TextField("Nombre", text: $fullName)
                        .textContentType(.name)
                    HStack {
                        Text("Edad")
                        Spacer()
                        TextField("ej. 30", text: $ageString)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Picker("Sexo", selection: $sex) {
                        Text("Masculino").tag("male")
                        Text("Femenino").tag("female")
                        Text("Otro").tag("other")
                    }
                }

                Section("Cuerpo") {
                    HStack {
                        Text("Altura (cm)")
                        Spacer()
                        TextField("ej. 175", text: $heightString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Peso actual (kg)")
                        Spacer()
                        TextField("ej. 70", text: $weightString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Peso objetivo (kg)")
                        Spacer()
                        TextField("opcional", text: $targetWeightString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Actividad y objetivo") {
                    Picker("Nivel de actividad", selection: $activityLevel) {
                        Text("Sedentario").tag("sedentary")
                        Text("Ligero").tag("lightly_active")
                        Text("Moderado").tag("moderately_active")
                        Text("Activo").tag("very_active")
                        Text("Muy activo").tag("extremely_active")
                    }
                    Picker("Objetivo", selection: $goal) {
                        Text("Perder peso").tag("lose_weight")
                        Text("Mantener").tag("maintain")
                        Text("Ganar músculo").tag("gain_muscle")
                        Text("Recomposición").tag("recomposition")
                        Text("Salud").tag("health")
                        Text("Rendimiento").tag("performance")
                    }
                }

                Section("Alimentación") {
                    TextField("Estilo (ej. vegetariano)", text: $dietaryStyle)
                    TextField("Alergias (separadas por comas)", text: $allergens, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Restricciones (ej. sin gluten)", text: $restrictions, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Salud y vida") {
                    TextField("Condiciones médicas", text: $medicalConditions, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Contexto del hogar", text: $householdContext, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Habilidad culinaria", selection: $cookingSkill) {
                        Text("Principiante").tag("beginner")
                        Text("Intermedio").tag("intermediate")
                        Text("Avanzado").tag("advanced")
                    }
                    HStack {
                        Text("Presupuesto (€/semana)")
                        Spacer()
                        TextField("opcional", text: $budgetString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section {
                    if let err = errorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Guardar perfil").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("Editar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await loadProfile()
            }
        }
    }

    private func loadProfile() async {
        // El perfil puede estar en auth.profile (ya cargado) o en BD
        let p = auth.profile
        fullName = p?.fullName ?? ""
        if let birth = p?.birthDate, let year = Int(birth.prefix(4)) {
            let thisYear = Calendar.current.component(.year, from: Date())
            ageString = "\(thisYear - year)"
        }
        sex = p?.sex ?? "male"
        if let h = p?.heightCm { heightString = String(Int(h)) }
        if let w = p?.weightKg { weightString = String(w) }
        if let tw = p?.targetWeightKg { targetWeightString = String(tw) }
        activityLevel = p?.activityLevel ?? "moderately_active"
        goal = p?.goal ?? "maintain"
        dietaryStyle = (p?.dietaryStyle ?? []).joined(separator: ", ")
        allergens = (p?.allergens ?? []).joined(separator: ", ")
        restrictions = (p?.restrictions ?? []).joined(separator: ", ")
        medicalConditions = (p?.medicalConditions ?? []).joined(separator: ", ")
        householdContext = p?.householdContext ?? ""
        cookingSkill = p?.cookingSkill ?? "intermediate"
        if let b = p?.budgetEurPerWeek { budgetString = String(b) }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        // Calcular año de nacimiento desde edad
        var birthDate: String? = nil
        if let age = Int(ageString), age > 0 {
            let year = Calendar.current.component(.year, from: Date()) - age
            birthDate = "\(year)-01-01"
        }

        // Construir update payload
        struct UpdatePayload: Encodable {
            let full_name: String?
            let birth_date: String?
            let sex: String?
            let height_cm: Double?
            let weight_kg: Double?
            let target_weight_kg: Double?
            let activity_level: String?
            let goal: String?
            let dietary_style: [String]?
            let allergens: [String]?
            let restrictions: [String]?
            let medical_conditions: [String]?
            let household_context: String?
            let cooking_skill: String?
            let budget_eur_per_week: Double?
        }

        let payload = UpdatePayload(
            full_name: fullName.isEmpty ? nil : fullName,
            birth_date: birthDate,
            sex: sex,
            height_cm: Double(heightString),
            weight_kg: Double(weightString),
            target_weight_kg: Double(targetWeightString),
            activity_level: activityLevel,
            goal: goal,
            dietary_style: splitList(dietaryStyle),
            allergens: splitList(allergens),
            restrictions: splitList(restrictions),
            medical_conditions: splitList(medicalConditions),
            household_context: householdContext.isEmpty ? nil : householdContext,
            cooking_skill: cookingSkill,
            budget_eur_per_week: Double(budgetString)
        )

        do {
            let userId = try await SupabaseService.shared.client.auth.session.user.id.uuidString
            try await SupabaseService.shared.client
                .from("profiles")
                .update(payload)
                .eq("id", value: userId)
                .execute()

            // Recargar perfil en auth
            await auth.restoreSession()
            dismiss()
        } catch {
            errorMessage = "Error guardando: \(error.localizedDescription)"
        }
    }

    private func splitList(_ text: String) -> [String]? {
        let parts = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }
}