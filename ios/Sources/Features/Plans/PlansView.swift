// ============================================================
// PlansView - planes de dieta (activo + historial + generador)
// ============================================================

import SwiftUI

struct PlansView: View {
    @StateObject private var viewModel = PlansViewModel()
    @State private var showGenerateSheet: Bool = false
    @State private var selectedDayIndex: Int = 0
    @State private var selectedPlanForDetail: MealPlan?
    @State private var selectedMealForDetail: PlanMeal?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.isLoading && viewModel.activePlan == nil {
                        loadingView
                    } else if let active = viewModel.activePlan {
                        activePlanSection(active)
                        if !viewModel.otherPlans.isEmpty {
                            historySection
                        }
                    } else if !viewModel.otherPlans.isEmpty {
                        // No hay plan activo pero hay planes
                        noActivePlanSection
                        historySection
                    } else {
                        emptyStateSection
                    }

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Planes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGenerateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                    .disabled(viewModel.isGenerating)
                }
            }
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.refresh()
            }
            .sheet(isPresented: $showGenerateSheet) {
                GeneratePlanSheet(
                    isPresented: $showGenerateSheet,
                    isGenerating: $viewModel.isGenerating,
                    onGenerate: { type, notes in
                        Task {
                            await viewModel.generatePlan(type: type, notes: notes)
                            showGenerateSheet = false
                        }
                    }
                )
            }
            .sheet(item: $selectedPlanForDetail) { plan in
                PlanDetailView(plan: plan, viewModel: viewModel) {
                    selectedPlanForDetail = nil
                }
            }
            .sheet(item: $selectedMealForDetail) { meal in
                PlanMealDetailView(meal: meal, viewModel: viewModel)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Cargando planes...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Empty state

    private var emptyStateSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "list.bullet.rectangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)
            Text("No tienes planes aún")
                .font(.title3.bold())
            Text("Genera un plan de comida personalizado basado en tu perfil, objetivo y preferencias.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showGenerateSheet = true
            } label: {
                Label("Generar plan", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.green, in: Capsule())
            }

            Text("También puedes pedirle al coach desde el chat: \"Hazme un plan semanal\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 40)
    }

    // MARK: - No active plan

    private var noActivePlanSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("No tienes un plan activo")
                .font(.headline)
            Text("Tienes \(viewModel.otherPlans.count) plan(es) en borrador. Activa uno para seguirlo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Active plan

    private func activePlanSection(_ plan: MealPlan) -> some View {
        VStack(spacing: 16) {
            // Cabecera del plan
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.plan.title)
                            .font(.title2.bold())
                        HStack(spacing: 8) {
                            Label(plan.plan.type == .weekly ? "Semanal" : "Diario",
                                  systemImage: plan.plan.type == .weekly ? "calendar" : "calendar.day")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            StatusBadge(status: plan.status)
                        }
                    }
                    Spacer()
                }

                if !plan.plan.summary.isEmpty {
                    Text(plan.plan.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Targets de macros
                if let kcal = plan.plan.targetKcal {
                    HStack(spacing: 16) {
                        TargetPill(label: "kcal", value: "\(kcal)", color: .orange)
                        if let p = plan.plan.targetProteinG {
                            TargetPill(label: "Prot", value: "\(p)g", color: .red)
                        }
                        if let c = plan.plan.targetCarbsG {
                            TargetPill(label: "Carb", value: "\(c)g", color: .blue)
                        }
                        if let f = plan.plan.targetFatG {
                            TargetPill(label: "Gras", value: "\(f)g", color: .yellow)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            // Selector de dia (si hay mas de 1)
            if plan.plan.days.count > 1 {
                daySelector(plan)
            }

            // Comidas del dia seleccionado
            if selectedDayIndex < plan.plan.days.count {
                let day = plan.plan.days[selectedDayIndex]
                VStack(spacing: 12) {
                    Text(day.day.capitalized)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    ForEach(day.meals) { meal in
                        Button {
                            selectedMealForDetail = meal
                        } label: {
                            PlanMealCard(meal: meal)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
            }
        }
    }

    private func daySelector(_ plan: MealPlan) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(plan.plan.days.enumerated()), id: \.element.id) { index, day in
                        Button {
                            withAnimation { selectedDayIndex = index }
                        } label: {
                            Text(day.day.prefix(3).capitalized)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    selectedDayIndex == index
                                        ? Color.green
                                        : Color(.secondarySystemBackground)
                                )
                                .foregroundStyle(selectedDayIndex == index ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planes anteriores")
                .font(.headline)
                .padding(.horizontal)

            ForEach(viewModel.otherPlans) { plan in
                PlanHistoryRow(plan: plan) {
                    selectedPlanForDetail = plan
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: PlanStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch status {
        case .draft: return .gray
        case .active: return .green
        case .completed: return .blue
        case .archived: return .secondary
        }
    }
}

// MARK: - Target Pill

private struct TargetPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Plan Meal Card

private struct PlanMealCard: View {
    let meal: PlanMeal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meal.type.icon)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(meal.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(meal.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let notes = meal.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Metadata rapida: tiempo + dificultad
                if meal.totalTimeMinutes != nil || meal.difficulty != nil {
                    HStack(spacing: 8) {
                        if let mins = meal.totalTimeMinutes {
                            Label("\(mins) min", systemImage: "clock")
                        }
                        if let diff = meal.difficulty {
                            Label(diff.label, systemImage: diff.icon)
                                .foregroundStyle(colorForDifficulty(diff))
                        }
                        if let ings = meal.ingredients, !ings.isEmpty {
                            Label("\(ings.count) ing.", systemImage: "list.bullet")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Macros compactos
            VStack(alignment: .trailing, spacing: 2) {
                if let kcal = meal.kcal {
                    Text("\(Int(kcal))")
                        .font(.subheadline.weight(.semibold))
                    Text("kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func colorForDifficulty(_ d: PlanMealDifficulty) -> Color {
        switch d {
        case .facil: return .green
        case .media: return .orange
        case .alta: return .red
        }
    }
}

// MARK: - Plan History Row

private struct PlanHistoryRow: View {
    let plan: MealPlan
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: plan.plan.type == .weekly ? "calendar" : "calendar.day")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.plan.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Text(plan.plan.type == .weekly ? "Semanal" : "Diario")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        StatusBadge(status: plan.status)
                        Text(formatDate(plan.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ iso: String) -> String {
        let date = DateParsing.parse(iso) ?? Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "es_ES")
        return formatter.string(from: date)
    }
}

// MARK: - Generate Plan Sheet

private struct GeneratePlanSheet: View {
    @Binding var isPresented: Bool
    @Binding var isGenerating: Bool
    let onGenerate: (PlanType, String?) -> Void

    @State private var selectedType: PlanType = .weekly
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de plan") {
                    Picker("Duración", selection: $selectedType) {
                        Label("Semanal (7 días)", systemImage: "calendar")
                            .tag(PlanType.weekly)
                        Label("Diario (hoy)", systemImage: "calendar.day")
                            .tag(PlanType.daily)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Notas (opcional)") {
                    TextField("Ej: sin lactosa, comida para llevar al trabajo...", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        onGenerate(selectedType, notes.isEmpty ? nil : notes)
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(isGenerating ? "Generando..." : "Generar plan")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isGenerating)
                }
            }
            .navigationTitle("Generar plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        isPresented = false
                    }
                    .disabled(isGenerating)
                }
            }
            .interactiveDismissDisabled(isGenerating)
        }
    }
}

// MARK: - Plan Detail View

private struct PlanDetailView: View {
    let plan: MealPlan
    @ObservedObject var viewModel: PlansViewModel
    let onAction: () -> Void

    @State private var selectedDayIndex: Int = 0
    @State private var showDeleteConfirm: Bool = false
    @State private var selectedMealForDetail: PlanMeal?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Cabecera
                    VStack(spacing: 8) {
                        Text(plan.plan.title)
                            .font(.title2.bold())
                        HStack(spacing: 8) {
                            Label(plan.plan.type == .weekly ? "Semanal" : "Diario",
                                  systemImage: plan.plan.type == .weekly ? "calendar" : "calendar.day")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            StatusBadge(status: plan.status)
                        }
                        if !plan.plan.summary.isEmpty {
                            Text(plan.plan.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Targets de macros
                        if let kcal = plan.plan.targetKcal {
                            HStack(spacing: 16) {
                                TargetPill(label: "kcal", value: "\(kcal)", color: .orange)
                                if let p = plan.plan.targetProteinG {
                                    TargetPill(label: "Prot", value: "\(p)g", color: .red)
                                }
                                if let c = plan.plan.targetCarbsG {
                                    TargetPill(label: "Carb", value: "\(c)g", color: .blue)
                                }
                                if let f = plan.plan.targetFatG {
                                    TargetPill(label: "Gras", value: "\(f)g", color: .yellow)
                                }
                            }
                        }
                    }
                    .padding()

                    // Botones de accion
                    actionButtons

                    // Selector de dia
                    if plan.plan.days.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(plan.plan.days.enumerated()), id: \.element.id) { index, day in
                                    Button {
                                        withAnimation { selectedDayIndex = index }
                                    } label: {
                                        Text(day.day.prefix(3).capitalized)
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedDayIndex == index
                                                    ? Color.green
                                                    : Color(.secondarySystemBackground)
                                            )
                                            .foregroundStyle(selectedDayIndex == index ? .white : .primary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Comidas del dia
                    if selectedDayIndex < plan.plan.days.count {
                        let day = plan.plan.days[selectedDayIndex]
                        VStack(spacing: 12) {
                            Text(day.day.capitalized)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)

                            ForEach(day.meals) { meal in
                                Button {
                                    selectedMealForDetail = meal
                                } label: {
                                    PlanMealCard(meal: meal)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Detalle del plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(item: $selectedMealForDetail) { meal in
                PlanMealDetailView(meal: meal, viewModel: viewModel)
            }
            .confirmationDialog("¿Borrar este plan?", isPresented: $showDeleteConfirm) {
                Button("Borrar", role: .destructive) {
                    Task {
                        await viewModel.deletePlan(plan)
                        onAction()
                        dismiss()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta acción no se puede deshacer.")
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 8) {
            if plan.status != .active {
                Button {
                    Task {
                        await viewModel.activatePlan(plan)
                        onAction()
                        dismiss()
                    }
                } label: {
                    Label("Activar plan", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.green, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if plan.status == .active {
                Button {
                    Task {
                        await viewModel.archivePlan(plan)
                        onAction()
                        dismiss()
                    }
                } label: {
                    Label("Archivar", systemImage: "archivebox.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Borrar plan", systemImage: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Plan Meal Detail View

private struct PlanMealDetailView: View {
    let meal: PlanMeal
    @ObservedObject var viewModel: PlansViewModel

    @State private var isLogging: Bool = false
    @State private var logResult: LogResult?
    @Environment(\.dismiss) var dismiss

    enum LogResult {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    macrosSection
                    metaSection
                    ingredientsSection
                    preparationSection
                    tipsSection
                    allergensSection
                    logButton
                }
                .padding(.vertical)
            }
            .navigationTitle(meal.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .alert("Comida registrada", isPresented: Binding(
                get: { logResult != nil },
                set: { if !$0 { logResult = nil } }
            )) {
                Button("OK") { logResult = nil }
            } message: {
                if case .failure(let msg) = logResult {
                    Text(msg)
                } else {
                    Text("\(meal.name) añadida a tu registro de hoy.")
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: meal.type.icon)
                .font(.system(size: 48))
                .foregroundStyle(.green.gradient)

            Text(meal.type.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let notes = meal.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Macros

    private var macrosSection: some View {
        VStack(spacing: 12) {
            // Kcal principal
            if let kcal = meal.kcal {
                VStack(spacing: 2) {
                    Text("\(Int(kcal))")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Macros detallados
            HStack(spacing: 12) {
                MacroPill(label: "Proteina", value: meal.proteinG, unit: "g", color: .red)
                MacroPill(label: "Carbos", value: meal.carbsG, unit: "g", color: .blue)
                MacroPill(label: "Grasas", value: meal.fatG, unit: "g", color: .yellow)
                MacroPill(label: "Fibra", value: meal.fiberG, unit: "g", color: .brown)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Metadata (tiempo, dificultad, raciones)

    private var metaSection: some View {
        let hasMeta = meal.totalTimeMinutes != nil || meal.difficulty != nil || meal.servings != nil
        return Group {
            if hasMeta {
                HStack(spacing: 16) {
                    if let total = meal.totalTimeMinutes {
                        MetaChip(icon: "clock", label: "\(total) min", subtitle: tiempoDesglose)
                    }
                    if let diff = meal.difficulty {
                        MetaChip(icon: diff.icon, label: diff.label, subtitle: "Dificultad", color: colorForDifficulty(diff))
                    }
                    if let servings = meal.servings {
                        MetaChip(icon: "person.2", label: "\(servings)", subtitle: servings == 1 ? "Racion" : "Raciones")
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var tiempoDesglose: String {
        let prep = meal.prepTimeMinutes ?? 0
        let cook = meal.cookTimeMinutes ?? 0
        if prep > 0 && cook > 0 {
            return "prep \(prep) + coc \(cook)"
        } else if prep > 0 {
            return "prep \(prep)"
        } else if cook > 0 {
            return "coc \(cook)"
        }
        return "tiempo total"
    }

    // MARK: - Ingredientes

    private var ingredientsSection: some View {
        Group {
            if let ings = meal.ingredients, !ings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Ingredientes", systemImage: "list.bullet.rectangle")
                        .font(.headline)

                    VStack(spacing: 8) {
                        ForEach(Array(ings.enumerated()), id: \.element.id) { index, ing in
                            HStack {
                                Text(ing.name)
                                    .font(.subheadline)
                                Spacer()
                                if let q = ing.quantity, let u = ing.unit {
                                    Text("\(formatQuantity(q)) \(u)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let q = ing.quantity {
                                    Text(formatQuantity(q))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let u = ing.unit, !u.isEmpty {
                                    Text(u)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if index < ings.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Preparacion

    private var preparationSection: some View {
        Group {
            if let prep = meal.preparation, !prep.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Preparacion", systemImage: "fork.knife")
                        .font(.headline)

                    Text(prep)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Tips

    private var tipsSection: some View {
        Group {
            if let tips = meal.tips, !tips.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Tips", systemImage: "lightbulb.fill")
                        .font(.headline)
                        .foregroundStyle(.yellow)

                    Text(tips)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Alérgenos

    private var allergensSection: some View {
        Group {
            if let allergens = meal.allergens, !allergens.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Alérgenos", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    FlowLayout(spacing: 8) {
                        ForEach(allergens, id: \.self) { allergen in
                            Text(allergen.capitalized)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Registrar comida

    private var logButton: some View {
        Button {
            Task {
                isLogging = true
                let ok = await viewModel.logMealFromPlan(meal)
                isLogging = false
                logResult = ok ? .success : .failure(viewModel.errorMessage ?? "Error desconocido")
            }
        } label: {
            HStack {
                if isLogging {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus.circle.fill")
                }
                Text(isLogging ? "Registrando..." : "Registrar como comida de hoy")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.green, in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isLogging)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func formatQuantity(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.1f", q)
    }

    private func colorForDifficulty(_ d: PlanMealDifficulty) -> Color {
        switch d {
        case .facil: return .green
        case .media: return .orange
        case .alta: return .red
        }
    }
}

// MARK: - Macro Pill

private struct MacroPill: View {
    let label: String
    let value: Double?
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            if let v = value {
                Text("\(Int(v))\(unit)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
            } else {
                Text("--")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Meta Chip

private struct MetaChip: View {
    let icon: String
    let label: String
    let subtitle: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Flow Layout (para tags de alérgenos)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                totalHeight += currentRowHeight + spacing
                currentRowWidth = 0
                currentRowHeight = 0
            }
            rows[rows.count - 1].append(subview)
            currentRowWidth += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}