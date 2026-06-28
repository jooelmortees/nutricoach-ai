// ============================================================
// MealEditorSheet - editor visual de PendingMeal con estados
// ============================================================
//
// Flujo: la IA genera un JSON con macros + ingredientes -> el usuario
// edita los ingredientes (no las macros) -> al guardar se manda a la
// IA que recalcule las macros desde los ingredientes editados ->
// se muestran las macros actualizadas -> se guarda en la BD.
//
// Estados:
//   .editing       -> formulario editable (ingredientes) + macros read-only
//   .recalculating -> ProgressView mientras la IA recalcula
//   .saving        -> ProgressView mientras se guarda en la BD
//   .saved         -> check + resumen + boton Editar

import SwiftUI

struct MealEditorSheet: View {
    @Binding var meal: PendingMeal
    let onSave: (PendingMeal) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var phase: SavePhase = .editing
    @State private var saveError: String?

    private enum SavePhase {
        case editing
        case recalculating
        case saving
        case saved
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .editing:
                    editingContent
                case .recalculating:
                    recalculatingContent
                case .saving:
                    savingContent
                case .saved:
                    savedContent
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .editing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancelar") { dismiss() }
                    }
                }
                if phase == .saved {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Listo") { dismiss() }
                            .bold()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(phase == .recalculating || phase == .saving)
    }

    private var navigationTitle: String {
        switch phase {
        case .editing: return "Revisar comida"
        case .recalculating: return "Recalculando"
        case .saving: return "Guardando"
        case .saved: return "Guardado"
        }
    }

    // MARK: - Editing (macros read-only, ingredientes editables)

    private var editingContent: some View {
        Form {
            Section("Comida") {
                TextField("Nombre", text: $meal.description)
                Picker("Tipo", selection: Binding(
                    get: { meal.meal_type ?? "other" },
                    set: { meal.meal_type = $0 }
                )) {
                    Text("Desayuno").tag("breakfast")
                    Text("Comida").tag("lunch")
                    Text("Cena").tag("dinner")
                    Text("Snack").tag("snack")
                    Text("Otro").tag("other")
                }
            }

            // Macros en read-only: se recalculan desde los ingredientes
            Section {
                HStack {
                    macroDisplay(label: "Kcal", value: meal.kcal ?? 0, unit: "kcal", color: .orange)
                    macroDisplay(label: "Proteína", value: meal.protein_g ?? 0, unit: "g", color: .red)
                    macroDisplay(label: "Carbos", value: meal.carbs_g ?? 0, unit: "g", color: .green)
                    macroDisplay(label: "Grasas", value: meal.fat_g ?? 0, unit: "g", color: .yellow)
                }
            } header: {
                HStack {
                    Text("Macros estimados")
                    Spacer()
                    Text("(se recalculan al guardar)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ingredientes") {
                if let ings = meal.ingredients, !ings.isEmpty {
                    ForEach(ings) { ing in
                        HStack {
                            TextField("Ingrediente", text: ingredientNameBinding(for: ing))
                                .frame(maxWidth: .infinity)
                            TextField("Cant.", text: ingredientQtyBinding(for: ing))
                                .keyboardType(.decimalPad)
                                .frame(width: 60)
                            TextField("Unidad", text: ingredientUnitBinding(for: ing))
                                .frame(width: 70)
                        }
                    }
                } else {
                    Text("Sin ingredientes detectados")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = saveError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        await recalculateAndSave()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Recalcular y guardar")
                    }
                    .frame(maxWidth: .infinity)
                    .bold()
                }
            }
        }
    }

    private func macroDisplay(label: String, value: Double, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(value))")
                .font(.headline)
                .foregroundStyle(color)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Recalculating

    private var recalculatingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Calculando macros con la IA...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("A partir de los ingredientes editados")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Saving

    private var savingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Guardando...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Saved

    private var savedContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            VStack(spacing: 6) {
                Text("Guardado correctamente")
                    .font(.title3)
                    .bold()
                Text(meal.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let kcal = meal.kcal, kcal > 0 {
                HStack(spacing: 16) {
                    Text("\(Int(kcal)) kcal")
                        .font(.headline)
                    if let p = meal.protein_g { Text("P \(Int(p))g").foregroundStyle(.red) }
                    if let c = meal.carbs_g { Text("C \(Int(c))g").foregroundStyle(.green) }
                    if let f = meal.fat_g { Text("G \(Int(f))g").foregroundStyle(.yellow) }
                }
                .font(.subheadline)
            }
            Button {
                phase = .editing
                saveError = nil
            } label: {
                HStack {
                    Image(systemName: "pencil")
                    Text("Editar")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Lógica

    /// Llama a la edge function recalculate-macros con los ingredientes editados,
    /// actualiza las macros del meal y luego guarda en la BD.
    private func recalculateAndSave() async {
        saveError = nil
        phase = .recalculating

        do {
            let recalculated = try await callRecalculateMacros()
            // Actualizar las macros del meal con los valores recalculados
            meal.kcal = recalculated.kcal
            meal.protein_g = recalculated.protein_g
            meal.carbs_g = recalculated.carbs_g
            meal.fat_g = recalculated.fat_g
            if let newName = recalculated.description, !newName.isEmpty {
                meal.description = newName
            }

            // Ahora guardar en la BD
            phase = .saving
            let ok = await onSave(meal)
            if ok {
                phase = .saved
            } else {
                saveError = "No se pudo guardar. Inténtalo de nuevo."
                phase = .editing
            }
        } catch {
            saveError = "Error recalculando: \(error.localizedDescription)"
            phase = .editing
        }
    }

    /// Llama a la edge function recalculate-macros y devuelve los macros calculados.
    private func callRecalculateMacros() async throws -> RecalculatedMacros {
        let url = Config.supabaseURL.appending(path: "functions/v1/recalculate-macros")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = [
            "name": meal.description,
            "meal_type": meal.meal_type ?? "other",
            "ingredients": (meal.ingredients ?? []).map { ing in
                [
                    "name": ing.name,
                    "quantity": ing.quantity ?? 0,
                    "unit": ing.unit
                ] as [String: Any]
            }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "?"
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MealEditorError.recalculateFailed("HTTP \(code): \(body)")
        }

        let decoded = try JSONDecoder().decode(RecalculatedMacros.self, from: data)
        return decoded
    }

    private func getAccessToken() async throws -> String {
        let session = try await SupabaseService.shared.client.auth.session
        return session.accessToken
    }

    // MARK: - Ingredient bindings

    private func ingredientNameBinding(for ing: PendingIngredient) -> Binding<String> {
        Binding(
            get: { ing.name },
            set: { newValue in
                if let idx = meal.ingredients?.firstIndex(where: { $0.id == ing.id }) {
                    meal.ingredients?[idx].name = newValue
                }
            }
        )
    }

    private func ingredientQtyBinding(for ing: PendingIngredient) -> Binding<String> {
        Binding(
            get: { ing.quantity.map { String(format: "%.0f", $0) } ?? "" },
            set: { newValue in
                if let idx = meal.ingredients?.firstIndex(where: { $0.id == ing.id }) {
                    meal.ingredients?[idx].quantity = Double(newValue.replacingOccurrences(of: ",", with: "."))
                }
            }
        )
    }

    private func ingredientUnitBinding(for ing: PendingIngredient) -> Binding<String> {
        Binding(
            get: { ing.unit },
            set: { newValue in
                if let idx = meal.ingredients?.firstIndex(where: { $0.id == ing.id }) {
                    meal.ingredients?[idx].unit = newValue
                }
            }
        )
    }
}

// MARK: - Tipos auxiliares

struct RecalculatedMacros: Decodable {
    let description: String?
    let meal_type: String?
    let kcal: Double?
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let ingredients: [RecalculatedIngredient]?
    let confidence: Double?
}

struct RecalculatedIngredient: Decodable {
    let name: String
    let quantity: Double?
    let unit: String?
}

enum MealEditorError: LocalizedError {
    case recalculateFailed(String)

    var errorDescription: String? {
        switch self {
        case .recalculateFailed(let msg): return "Error recalculando macros: \(msg)"
        }
    }
}