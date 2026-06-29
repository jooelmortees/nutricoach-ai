// ============================================================
// LoggedMealEditorSheet - editor de una comida ya guardada
// ============================================================
//
// A diferencia de MealEditorSheet (que trabaja con PendingMeal
// del chat y recalcula macros via IA), este editor modifica
// directamente los campos de una LoggedMeal en la BD.

import SwiftUI

struct LoggedMealEditorSheet: View {
    let meal: LoggedMeal
    let onSave: (String, String, Double?, Double?, Double?, Double?) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var mealType: String = "other"
    @State private var kcalText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Comida") {
                    TextField("Nombre", text: $name)
                    Picker("Tipo", selection: $mealType) {
                        Text("Desayuno").tag("breakfast")
                        Text("Comida").tag("lunch")
                        Text("Cena").tag("dinner")
                        Text("Snack").tag("snack")
                        Text("Otro").tag("other")
                    }
                }

                Section("Macros") {
                    macroField(label: "Calorías (kcal)", text: $kcalText, color: .orange)
                    macroField(label: "Proteína (g)", text: $proteinText, color: .red)
                    macroField(label: "Carbohidratos (g)", text: $carbsText, color: .green)
                    macroField(label: "Grasas (g)", text: $fatText, color: .yellow)
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Guardar cambios")
                        }
                        .frame(maxWidth: .infinity)
                        .bold()
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Editar comida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .scaleEffect(1.3)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear { populate() }
    }

    private func populate() {
        name = meal.name
        mealType = meal.meal_type ?? "other"
        if let v = meal.total_kcal { kcalText = String(format: "%.0f", v) }
        if let v = meal.total_protein_g { proteinText = String(format: "%.0f", v) }
        if let v = meal.total_carbs_g { carbsText = String(format: "%.0f", v) }
        if let v = meal.total_fat_g { fatText = String(format: "%.0f", v) }
    }

    private func macroField(label: String, text: Binding<String>, color: Color) -> some View {
        HStack {
            Image(systemName: "circle.fill")
                .foregroundStyle(color)
                .font(.caption)
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        let kcal = Double(kcalText.replacingOccurrences(of: ",", with: "."))
        let protein = Double(proteinText.replacingOccurrences(of: ",", with: "."))
        let carbs = Double(carbsText.replacingOccurrences(of: ",", with: "."))
        let fat = Double(fatText.replacingOccurrences(of: ",", with: "."))
        await onSave(name.trimmingCharacters(in: .whitespaces), mealType, kcal, protein, carbs, fat)
        isSaving = false
        dismiss()
    }
}