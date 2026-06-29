// ============================================================
// PlansView - planes de dieta (activo + historial + generador)
// ============================================================

import SwiftUI

struct PlansView: View {
    @StateObject private var viewModel = PlansViewModel()
    @State private var showGenerateSheet: Bool = false
    @State private var selectedDayIndex: Int = 0
    @State private var selectedPlanForDetail: MealPlan?

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
                PlanDetailView(plan: plan)
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
                        PlanMealCard(meal: meal)
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
                if let notes = meal.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
    @State private var selectedDayIndex: Int = 0
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
                    }
                    .padding()

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
                                PlanMealCard(meal: meal)
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
        }
    }
}