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
                    summaryCards
                    targetComparison
                    mealsList
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
                await viewModel.load(userId: auth.profile?.id)
            }
            .refreshable {
                await viewModel.refresh(userId: auth.profile?.id)
            }
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MacroCard(
                title: "Calorías",
                value: "\(Int(viewModel.totals.kcal))",
                unit: "kcal",
                icon: "flame.fill",
                color: .orange
            )
            MacroCard(
                title: "Proteínas",
                value: "\(Int(viewModel.totals.protein))",
                unit: "g",
                icon: "figure.strengthtraining.traditional",
                color: .red
            )
            MacroCard(
                title: "Carbohidratos",
                value: "\(Int(viewModel.totals.carbs))",
                unit: "g",
                icon: "leaf.fill",
                color: .green
            )
            MacroCard(
                title: "Grasas",
                value: "\(Int(viewModel.totals.fat))",
                unit: "g",
                icon: "drop.fill",
                color: .yellow
            )
        }
    }

    private var targetComparison: some View {
        Group {
            if let target = viewModel.profile?.dailyKcalTarget, target > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Objetivo diario")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(viewModel.totals.kcal)) / \(target) kcal")
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(Double(viewModel.totals.kcal) / Double(target), 1.0))
                        .tint(viewModel.totals.kcal > Double(target) ? .red : .green)
                    HStack {
                        Text("Restante: \(max(target - Int(viewModel.totals.kcal), 0)) kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack {
                    Image(systemName: "target")
                        .foregroundStyle(.secondary)
                    Text("Configura tu objetivo diario en Ajustes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var mealsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comidas de hoy")
                .font(.headline)
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

struct MacroCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2)
                    .bold()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MealRow: View {
    let meal: LoggedMeal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mealIcon)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.description)
                    .font(.body)
                if let kcal = meal.kcal {
                    HStack(spacing: 8) {
                        Text("\(Int(kcal)) kcal")
                        if let p = meal.protein_g { Text("· P \(Int(p))g") }
                        if let c = meal.carbs_g { Text("· C \(Int(c))g") }
                        if let f = meal.fat_g { Text("· G \(Int(f))g") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(meal.consumedAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var mealIcon: String {
        switch meal.meal_type {
        case "breakfast": return "sun.horizon.fill"
        case "lunch": return "sun.max.fill"
        case "dinner": return "moon.fill"
        case "snack": return "leaf.fill"
        default: return "fork.knife"
        }
    }
}