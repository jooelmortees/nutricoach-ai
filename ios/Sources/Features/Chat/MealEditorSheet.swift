// ============================================================
// MealEditorSheet - editor visual de PendingMeal con estados
// ============================================================
//
// Flujo: la IA genera un JSON de macros -> el usuario lo revisa,
// edita si algo no cuadra y guarda. Tres estados:
//   .editing  -> formulario editable + boton "Guardar"
//   .saving   -> ProgressView + texto "Guardando..."
//   .saved    -> check + "Guardado correctamente" + boton "Editar"

import SwiftUI

struct MealEditorSheet: View {
    @Binding var meal: PendingMeal
    let onSave: (PendingMeal) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var phase: SavePhase = .editing
    @State private var saveError: String?

    private enum SavePhase {
        case editing
        case saving
        case saved
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .editing:
                    editingContent
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
        .interactiveDismissDisabled(phase == .saving)
    }

    private var navigationTitle: String {
        switch phase {
        case .editing: return "Revisar comida"
        case .saving: return "Guardando"
        case .saved: return "Guardado"
        }
    }

    // MARK: - Editing

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

            Section("Macros") {
                HStack {
                    macroField(label: "Kcal", value: Binding(
                        get: { String(format: "%.0f", meal.kcal ?? 0) },
                        set: { meal.kcal = Double($0.replacingOccurrences(of: ",", with: ".")) }
                    ), unit: "kcal")
                }
                HStack {
                    macroField(label: "Proteínas", value: Binding(
                        get: { String(format: "%.0f", meal.protein_g ?? 0) },
                        set: { meal.protein_g = Double($0.replacingOccurrences(of: ",", with: ".")) }
                    ), unit: "g")
                    macroField(label: "Carbos", value: Binding(
                        get: { String(format: "%.0f", meal.carbs_g ?? 0) },
                        set: { meal.carbs_g = Double($0.replacingOccurrences(of: ",", with: ".")) }
                    ), unit: "g")
                }
                HStack {
                    macroField(label: "Grasas", value: Binding(
                        get: { String(format: "%.0f", meal.fat_g ?? 0) },
                        set: { meal.fat_g = Double($0.replacingOccurrences(of: ",", with: ".")) }
                    ), unit: "g")
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
                        phase = .saving
                        saveError = nil
                        let ok = await onSave(meal)
                        if ok {
                            phase = .saved
                        } else {
                            saveError = "No se pudo guardar. Inténtalo de nuevo."
                            phase = .editing
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Guardar comida")
                    }
                    .frame(maxWidth: .infinity)
                    .bold()
                }
            }
        }
    }

    private func macroField(label: String, value: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("0", text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
}