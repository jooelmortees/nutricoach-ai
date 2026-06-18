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
                VStack(spacing: 16) {
                    if !viewModel.hasAuthorizedHealthKit {
                        healthKitPrompt
                    }
                    summaryCards
                    if viewModel.isSyncing {
                        HStack { ProgressView(); Text("Sincronizando HealthKit...") }
                            .padding()
                    }
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

    private var healthKitPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red.gradient)
            Text("Conecta Apple Health")
                .font(.headline)
            Text("Para que tu agente sepa tus pasos, FC, sueño y entrenamientos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.requestHealthKit() }
            } label: {
                Text("Conectar")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.red.gradient, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "Pasos",
                value: viewModel.steps.map { "\(Int($0))" } ?? "—",
                icon: "figure.walk",
                color: .green
            )
            metricCard(
                title: "Calorías activas",
                value: viewModel.activeEnergy.map { "\(Int($0)) kcal" } ?? "—",
                icon: "flame.fill",
                color: .orange
            )
            metricCard(
                title: "FC reposo",
                value: viewModel.restingHR.map { "\(Int($0)) lpm" } ?? "—",
                icon: "heart.fill",
                color: .red
            )
            metricCard(
                title: "Sueño",
                value: viewModel.sleepMinutes.map { "\(Int($0 / 60))h \($0.truncatingRemainder(dividingBy: 60).description.prefix(2))m" } ?? "—",
                icon: "bed.double.fill",
                color: .blue
            )
        }
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title2)
                .bold()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var hasAuthorizedHealthKit = false
    @Published var steps: Double?
    @Published var activeEnergy: Double?
    @Published var restingHR: Double?
    @Published var sleepMinutes: Double?
    @Published var isSyncing = false
    @Published var errorMessage: String?

    func loadInitial() async {
        await HealthKitManager.shared.syncToBackend(days: 1)
        await loadTodaySummary()
    }

    func refresh() async {
        await HealthKitManager.shared.syncToBackend(days: 1)
        await loadTodaySummary()
    }

    func requestHealthKit() async {
        do {
            try await HealthKitManager.shared.requestAuthorization()
            hasAuthorizedHealthKit = true
            await loadInitial()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadTodaySummary() async {
        do {
            let supabase = SupabaseService.shared.client
            struct Summary: Decodable {
                let date: String
                let kcal: Double?
                let protein_g: Double?
                let carbs_g: Double?
                let fat_g: Double?
                let meal_count: Int?
            }
            let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let _: Summary = try await supabase
                .rpc("get_daily_summary", params: ["p_date": String(today)])
                .execute()
                .value
            // Por ahora estos campos son de comidas, no de HK
            // En fase 2 cargamos también health_metrics
        } catch {
            // Silencioso si falla
        }

        // Cargar health_metrics para los 4 cards
        do {
            let supabase = SupabaseService.shared.client
            let start = Calendar.current.startOfDay(for: Date()).ISO8601Format()
            struct Metric: Decodable {
                let type: String
                let value: Double
            }
            let metrics: [Metric] = try await supabase
                .from("health_metrics")
                .select("type,value")
                .gte("recorded_at", value: start)
                .execute()
                .value

            // Sumar por tipo
            var totals: [String: Double] = [:]
            for m in metrics {
                totals[m.type, default: 0] += m.value
            }
            self.steps = totals["steps"] ?? totals["stepCount"]
            self.activeEnergy = totals["activeEnergyBurned"] ?? totals["active_energy"]
            self.restingHR = metrics.first(where: { $0.type.contains("restingHeartRate") })?.value
            self.sleepMinutes = totals["sleep_minutes"] ?? totals["sleepMinutes"]
        } catch {
            // ok, sin datos aún
        }
    }
}
