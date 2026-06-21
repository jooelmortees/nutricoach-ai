// ============================================================
// DashboardView - vista principal de salud y nutrición
// ============================================================

import SwiftUI
import HealthKit

struct DashboardView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header: saludo + kcal restantes
                    headerCard
                    // 4 metricas principales
                    summaryCards
                    // Grafico de pasos (ultimos 7 dias)
                    weeklyChart
                    // Boton de sincronizar
                    if let err = viewModel.errorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding()
            }
            .navigationTitle("Hoy")
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.loadInitial()
            }
        }
    }

    // MARK: - Sub-views

    private var headerCard: some View {
        let target = auth.profile?.dailyKcalTarget ?? 2000
        let consumed = Int(viewModel.todaysKcal)
        let remaining = max(target - consumed, 0)
        let progress = min(Double(consumed) / Double(target), 1.0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Hola\(auth.profile?.fullName.map { ", \($0)" } ?? "")")
                        .font(.title2).bold()
                    Text("Hoy llevas \(consumed) kcal de \(target)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(remaining)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(remaining == 0 ? .red : .green)
                    Text("kcal restantes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress)
                .tint(progress >= 1.0 ? .red : .green)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "Pasos",
                value: viewModel.steps.map { "\(Int($0))" } ?? "—",
                subtitle: viewModel.steps.map { "\(Int($0 / 1000))k" } ?? "—",
                icon: "figure.walk",
                color: .green
            )
            metricCard(
                title: "Calorías activas",
                value: viewModel.activeEnergy.map { "\(Int($0))" } ?? "—",
                subtitle: "kcal quemadas",
                icon: "flame.fill",
                color: .orange
            )
            metricCard(
                title: "FC reposo",
                value: viewModel.restingHR.map { "\(Int($0))" } ?? "—",
                subtitle: "lpm",
                icon: "heart.fill",
                color: .red
            )
            metricCard(
                title: "Sueño",
                value: viewModel.sleepHours.map { formatHours($0) } ?? "—",
                subtitle: "horas",
                icon: "bed.double.fill",
                color: .indigo
            )
        }
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                Text("Pasos esta semana")
                    .font(.headline)
                Spacer()
            }
            // Bar chart simple con 7 barras
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    let value = viewModel.weeklySteps[i]
                    let maxValue = viewModel.weeklySteps.max() ?? 1
                    VStack(spacing: 4) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(value > 0 ? Color.blue : Color(.tertiarySystemBackground))
                            .frame(height: maxValue > 0 ? max(CGFloat(value) / CGFloat(maxValue) * 80, 4) : 4)
                        Text(weekdayLabel(i))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.title2)
                .bold()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return "\(h)h \(m)m"
    }

    private func weekdayLabel(_ index: Int) -> String {
        let labels = ["L", "M", "X", "J", "V", "S", "D"]
        return labels[index]
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var steps: Double?
    @Published var activeEnergy: Double?
    @Published var restingHR: Double?
    @Published var sleepHours: Double?
    @Published var weeklySteps: [Int] = Array(repeating: 0, count: 7)
    @Published var todaysKcal: Double = 0
    @Published var hasAuthorizedHealthKit = false
    @Published var isSyncing = false
    @Published var errorMessage: String?

    func loadInitial() async {
        // Sincronizar HealthKit -> health_metrics
        await HealthKitManager.shared.syncToBackend(days: 7)
        await loadMetrics()
        await loadTodaysKcal()
    }

    func refresh() async {
        await loadInitial()
    }

    private func loadMetrics() async {
        do {
            let supabase = SupabaseService.shared.client
            let today = Calendar.current.startOfDay(for: Date())
            let weekAgo = Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today

            struct Metric: Decodable {
                let type: String
                let value: Double
                let recordedAt: String
                enum CodingKeys: String, CodingKey {
                    case type, value
                    case recordedAt = "recorded_at"
                }
            }

            // Cargar metricas de los ultimos 7 dias
            let metrics: [Metric] = try await supabase
                .from("health_metrics")
                .select("type,value,recorded_at")
                .gte("recorded_at", value: weekAgo.ISO8601Format())
                .execute()
                .value

            let calendar = Calendar.current
            let now = Date()

            // Agrupar por dia (ultimos 7)
            var stepsByDay: [Int: Double] = [:]
            var energyByDay: [Int: Double] = [:]

            for m in metrics {
                // Parsear fecha
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = f.date(from: m.recordedAt) ?? f.date(from: String(m.recordedAt.prefix(19)) + "Z") ?? now
                let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
                let idx = 6 - min(max(daysAgo, 0), 6)  // 0 = hace 6 dias, 6 = hoy
                if m.type.contains("step") {
                    stepsByDay[idx, default: 0] += m.value
                } else if m.type.contains("activeEnergy") {
                    energyByDay[idx, default: 0] += m.value
                }
            }

            // Calcular valores del dia (idx = 6)
            self.steps = stepsByDay[6]
            self.activeEnergy = energyByDay[6]

            // Llenar weeklySteps array
            self.weeklySteps = (0..<7).map { Int(stepsByDay[$0] ?? 0) }

            // FC reposo (ultimo valor del dia)
            self.restingHR = metrics
                .filter { $0.type.contains("restingHeartRate") }
                .filter { _ in
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let date = f.date(from: $0.recordedAt) ?? now
                    return calendar.isDate(date, inSameDayAs: now)
                }
                .first?.value

            // Sueño (suma de ayer noche o esta madrugada)
            self.sleepHours = metrics
                .filter { $0.type.contains("sleep") }
                .reduce(0.0) { $0 + $1.value } / 3600.0  // minutos a horas
        } catch {
            errorMessage = "Error cargando metricas: \(error.localizedDescription)"
        }
    }

    private func loadTodaysKcal() async {
        do {
            let supabase = SupabaseService.shared.client
            let today = Calendar.current.startOfDay(for: Date()).ISO8601Format()
            struct Meal: Decodable {
                let kcal: Double?
            }
            let meals: [Meal] = try await supabase
                .from("meals")
                .select("kcal")
                .gte("consumed_at", value: today)
                .execute()
                .value
            self.todaysKcal = meals.reduce(0) { $0 + ($1.kcal ?? 0) }
        } catch {
            // Silencioso
        }
    }
}