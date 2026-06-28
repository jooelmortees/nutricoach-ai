// ============================================================
// MacrosView - resumen de macros ingeridas hoy
// ============================================================

import SwiftUI

struct MacrosView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var viewModel = MacrosViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MacrosSummaryCards(viewModel: viewModel)
                    TargetComparisonView(viewModel: viewModel)
                    MealsListView(viewModel: viewModel)
                }
                .padding()
            }
            .navigationTitle("Macros")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await viewModel.load(userId: auth.profile?.id.uuidString)
            }
            .refreshable {
                await viewModel.refresh(userId: auth.profile?.id.uuidString)
            }
        }
    }
}

// MARK: - Sub-views (cada una con tipo explícito)

struct MacrosSummaryCards: View {
    @ObservedObject var viewModel: MacrosViewModel

    var body: some View {
        let t = viewModel.totals
        let p = viewModel.profile
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MacroRingCard(
                title: "Calorías",
                current: t.kcal,
                target: p?.dailyKcalTarget,
                unit: "kcal",
                color: .orange
            )
            MacroRingCard(
                title: "Proteínas",
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
            if let target, target > 0 {
                HStack {
                    Text("Objetivo diario").font(.headline)
                    Spacer()
                    Text("\(Int(t.kcal)) / \(target) kcal")
                        .foregroundStyle(.secondary)
                }
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

struct MealsListView: View {
    @ObservedObject var viewModel: MacrosViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comidas de hoy").font(.headline)
            if viewModel.meals.isEmpty {
                Text("Aún no has registrado ninguna comida. Envía una foto desde el chat o usa la cámara.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(viewModel.meals) { meal in
                    MealRow(meal: meal)
                }
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
                        if let p = meal.total_protein_g { Text("· P \(Int(p))g") }
                        if let c = meal.total_carbs_g { Text("· C \(Int(c))g") }
                        if let f = meal.total_fat_g { Text("· G \(Int(f))g") }
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