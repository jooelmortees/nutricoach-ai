// ============================================================
// MacrosView - resumen de macros ingeridas
// ============================================================

import SwiftUI

struct MacrosView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = MacrosViewModel()
    @State private var editingMeal: LoggedMeal?
    @State private var showingNewMeal = false
    @State private var showingCustomWater = false
    @State private var mealToDelete: LoggedMeal?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MacroHeatmapCalendar(viewModel: viewModel, userId: auth.profile?.id.uuidString) { date in
                        Task { await viewModel.selectDate(date, userId: auth.profile?.id.uuidString) }
                    }
                    MacrosSummaryCards(viewModel: viewModel)
                    TargetComparisonView(viewModel: viewModel)
                    WaterTrackerCard(
                        consumedMl: viewModel.waterTotalMl,
                        targetMl: viewModel.profile?.dailyWaterTargetMl ?? 2000,
                        latestLog: viewModel.waterLogs.last,
                        isMutating: viewModel.isWaterMutating || viewModel.isLoading,
                        onAdd: addWater,
                        onCustom: { showingCustomWater = true },
                        onUndo: undoWater
                    )
                    MealsListView(
                        viewModel: viewModel,
                        onEdit: { editingMeal = $0 },
                        onDelete: { meal in
                            mealToDelete = meal
                            showDeleteConfirm = true
                        }
                    )
                }
                .padding()
            }
            .navigationTitle("Macros")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        presentNewMeal()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Añadir comida")
                    .disabled(viewModel.isWaterMutating)

                    Button {
                        Task {
                            await viewModel.refresh(userId: auth.profile?.id.uuidString)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Actualizar")
                    .disabled(viewModel.isWaterMutating)
                }
            }
            .task {
                await viewModel.load(userId: auth.profile?.id.uuidString)
                handlePendingRoute(appState.pendingRoute)
            }
            .onChange(of: appState.pendingRoute) { _, route in
                handlePendingRoute(route)
            }
            .onChange(of: viewModel.isWaterMutating) { _, isMutating in
                if !isMutating {
                    handlePendingRoute(appState.pendingRoute)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await viewModel.handleDayChange(
                        userId: auth.profile?.id.uuidString
                    )
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .NSCalendarDayChanged
                )
            ) { _ in
                Task {
                    await viewModel.handleDayChange(
                        userId: auth.profile?.id.uuidString
                    )
                }
            }
            .refreshable {
                await viewModel.refresh(userId: auth.profile?.id.uuidString)
            }
            .sheet(item: $editingMeal) { meal in
                MealFormSheet(meal: meal) { name, type, kcal, p, c, f in
                    try await viewModel.updateMeal(
                        meal,
                        name: name,
                        mealType: type,
                        kcal: kcal,
                        protein: p,
                        carbs: c,
                        fat: f,
                        userId: auth.profile?.id.uuidString
                    )
                }
            }
            .sheet(isPresented: $showingNewMeal) {
                MealFormSheet(meal: nil) { name, type, kcal, p, c, f in
                    try await viewModel.addMeal(
                        name: name,
                        mealType: type,
                        kcal: kcal,
                        protein: p,
                        carbs: c,
                        fat: f,
                        userId: auth.profile?.id.uuidString
                    )
                }
            }
            .sheet(isPresented: $showingCustomWater) {
                WaterAmountSheet { amountMl in
                    try await viewModel.addWater(
                        amountMl: amountMl,
                        userId: auth.profile?.id.uuidString
                    )
                }
            }
            .confirmationDialog(
                "¿Eliminar \"\(mealToDelete?.name ?? "esta comida")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Eliminar", role: .destructive) {
                    if let meal = mealToDelete {
                        Task { await viewModel.deleteMeal(meal, userId: auth.profile?.id.uuidString) }
                    }
                    mealToDelete = nil
                }
                Button("Cancelar", role: .cancel) {
                    mealToDelete = nil
                }
            }
            .alert(
                "No se pudo completar la accion",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("Aceptar") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "Error desconocido")
            }
        }
    }

    private func addWater(_ amountMl: Int) {
        Task {
            do {
                try await viewModel.addWater(
                    amountMl: amountMl,
                    userId: auth.profile?.id.uuidString
                )
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func undoWater() {
        Task {
            do {
                try await viewModel.deleteLatestWater(
                    userId: auth.profile?.id.uuidString
                )
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func handlePendingRoute(_ route: AppState.Route?) {
        switch route {
        case .some(.newMeal):
            guard !viewModel.isWaterMutating else { return }
            appState.consume(route: .newMeal)
            presentNewMeal()
        case .some(.macros):
            appState.consume(route: .macros)
        case .none:
            break
        }
    }

    private func presentNewMeal() {
        guard !viewModel.isWaterMutating else { return }
        Task {
            await viewModel.selectDate(
                Date(),
                userId: auth.profile?.id.uuidString
            )
            showingNewMeal = true
        }
    }
}

// MARK: - Heatmap mensual

struct MacroHeatmapCalendar: View {
    @ObservedObject var viewModel: MacrosViewModel
    let userId: String?
    let onSelectDate: (Date) -> Void

    private var calendar: Calendar { viewModel.calendar }
    private let weekdays = ["L", "M", "X", "J", "V", "S", "D"]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    Task { await viewModel.changeMonth(by: -1, userId: userId) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body)
                        .bold()
                }
                Spacer()
                Text(viewModel.displayedMonth, format: .dateTime.month(.wide).year())
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.changeMonth(by: 1, userId: userId) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body)
                        .bold()
                }
            }

            HStack(spacing: 4) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = generateDays()
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let date = day {
                        HeatmapCell(
                            dayNumber: calendar.component(.day, from: date),
                            compliance: viewModel.compliance(for: date),
                            isSelected: calendar.isDate(date, inSameDayAs: viewModel.selectedDate),
                            isToday: calendar.isDateInToday(date)
                        ) {
                            onSelectDate(date)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                            .frame(height: 34)
                    }
                }
            }

            HStack(spacing: 12) {
                ForEach([
                    ("Por debajo", Color.orange.opacity(0.6)),
                    ("En objetivo", Color.green),
                    ("Por encima", Color.red.opacity(0.8)),
                    ("Sin datos", Color(.tertiarySystemFill))
                ], id: \.0) { label, color in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: 12, height: 12)
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func generateDays() -> [Date?] {
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: viewModel.displayedMonth))!
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let mondayOffset = (weekday + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: mondayOffset)
        let range = calendar.range(of: .day, in: .month, for: firstOfMonth)!
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        while days.count % 7 != 0 {
            days.append(nil)
        }
        return days
    }
}

struct HeatmapCell: View {
    let dayNumber: Int
    let compliance: MacrosViewModel.DayCompliance
    let isSelected: Bool
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 6)
                .fill(compliance.color)
                .frame(height: 34)
                .overlay {
                    Text("\(dayNumber)")
                        .font(.caption2)
                        .foregroundStyle(compliance == .noData ? Color.secondary : Color.white)
                        .bold(compliance == .onTrack)
                }
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sub-views

struct MacrosSummaryCards: View {
    @ObservedObject var viewModel: MacrosViewModel

    var body: some View {
        let t = viewModel.totals
        let p = viewModel.profile
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MacroRingCard(
                title: "Calorias",
                current: t.kcal,
                target: p?.dailyKcalTarget,
                unit: "kcal",
                color: .orange
            )
            MacroRingCard(
                title: "Proteinas",
                current: t.protein,
                target: p?.dailyProteinG,
                unit: "g",
                color: .red
            )
            MacroRingCard(
                title: "Carbohidratos",
                current: t.carbs,
                target: p?.dailyCarbsG,
                unit: "g",
                color: .green
            )
            MacroRingCard(
                title: "Grasas",
                current: t.fat,
                target: p?.dailyFatG,
                unit: "g",
                color: .yellow
            )
        }
    }
}

struct TargetComparisonView: View {
    @ObservedObject var viewModel: MacrosViewModel

    var body: some View {
        let t = viewModel.totals
        let target: Int? = viewModel.profile?.dailyKcalTarget
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.isToday ? "Objetivo de hoy" : "Objetivo del dia")
                    .font(.headline)
                Spacer()
                if let target, target > 0 {
                    Text("\(Int(t.kcal)) / \(target) kcal")
                        .foregroundStyle(.secondary)
                }
            }
            if let target, target > 0 {
                ProgressView(value: min(t.kcal / Double(target), 1.0))
                    .tint(t.kcal > Double(target) ? Color.red : Color.green)
                HStack {
                    Text("Restante: \(max(target - Int(t.kcal), 0)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack {
                    Image(systemName: "target").foregroundStyle(.secondary)
                    Text("Configura tu objetivo diario en Ajustes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct WaterTrackerCard: View {
    let consumedMl: Int
    let targetMl: Int
    let latestLog: WaterLog?
    let isMutating: Bool
    let onAdd: (Int) -> Void
    let onCustom: () -> Void
    let onUndo: () -> Void

    private var progress: Double {
        guard targetMl > 0 else { return 0 }
        return min(Double(consumedMl) / Double(targetMl), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Agua", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(consumedMl) / \(targetMl) ml")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(consumedMl > targetMl ? .blue : .cyan)

            HStack(spacing: 8) {
                waterButton(amountMl: 250)
                waterButton(amountMl: 500)
                Button(action: onCustom) {
                    Image(systemName: "ellipsis")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(isMutating)
                .help("Otra cantidad")

                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .disabled(latestLog == nil || isMutating)
                .help("Deshacer el ultimo vaso")
            }

            if let latestLog {
                Text("Ultimo: \(latestLog.amountMl) ml a las \(latestLog.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func waterButton(amountMl: Int) -> some View {
        Button { onAdd(amountMl) } label: {
            Label("\(amountMl) ml", systemImage: "plus")
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .disabled(isMutating)
    }
}

struct WaterAmountSheet: View {
    let onAdd: (Int) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "250"
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cantidad") {
                    HStack {
                        TextField("250", text: $amountText)
                            .keyboardType(.numberPad)
                        Text("ml")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Anadir agua")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anadir") { Task { await save() } }
                        .disabled(isSaving || amountText.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard let amountMl = Int(amountText), (1...5000).contains(amountMl) else {
            errorMessage = "Introduce una cantidad entre 1 y 5000 ml."
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            try await onAdd(amountMl)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct MealsListView: View {
    @ObservedObject var viewModel: MacrosViewModel
    let onEdit: (LoggedMeal) -> Void
    let onDelete: (LoggedMeal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.isToday ? "Comidas de hoy" : "Comidas del dia")
                    .font(.headline)
                Spacer()
                Text(viewModel.selectedDate, format: .dateTime.day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.meals.isEmpty {
                Text("No hay comidas registradas este dia. Envia una foto desde el chat o usa la camara.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(viewModel.meals) { meal in
                        MealRow(meal: meal)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) {
                                Button {
                                    onEdit(meal)
                                } label: {
                                    Label("Editar", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onDelete(meal)
                                } label: {
                                    Label("Eliminar", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(viewModel.meals.count) * 88 + 8)
            }
        }
    }
}

struct MacroRingCard: View {
    let title: String
    let current: Double
    let target: Int?
    let unit: String
    let color: Color

    private var progress: Double {
        guard let target, target > 0 else { return 0 }
        return min(current / Double(target), 1.0)
    }

    private var exceeded: Bool {
        guard let target, target > 0 else { return false }
        return current > Double(target)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 8)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: exceeded ? 1.0 : progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 72, height: 72)
                VStack(spacing: 0) {
                    Text("\(Int(current))")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(exceeded ? .red : color)
                    if let target {
                        Text("/ \(target)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let target {
                let remaining = max(target - Int(current), 0)
                if remaining > 0 {
                    Text("Quedan \(remaining) \(unit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if exceeded {
                    Text("+\(Int(current) - target) \(unit)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text("Objetivo alcanzado")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            } else {
                Text("Sin objetivo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MealRow: View {
    let meal: LoggedMeal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconForMeal)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.name).font(.body)
                if let kcal = meal.total_kcal {
                    HStack(spacing: 8) {
                        Text("\(Int(kcal)) kcal")
                        if let p = meal.total_protein_g { Text("- P \(Int(p))g") }
                        if let c = meal.total_carbs_g { Text("- C \(Int(c))g") }
                        if let f = meal.total_fat_g { Text("- G \(Int(f))g") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(meal.loggedAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var iconForMeal: String {
        switch meal.meal_type {
        case "breakfast": return "sun.horizon.fill"
        case "lunch": return "sun.max.fill"
        case "dinner": return "moon.fill"
        case "snack": return "leaf.fill"
        default: return "fork.knife"
        }
    }
}
