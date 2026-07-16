import SwiftUI
import WidgetKit

struct MacrosWidget: Widget {
    static let kind = "com.joelmortees.nutricoach.macros"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DailyTrackingProvider()) { entry in
            MacrosWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Macros de hoy")
        .description("Muestra lo consumido y lo que queda para tu objetivo diario.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct MacrosWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyTrackingEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumView
            } else {
                smallView
            }
        }
        .widgetURL(WidgetLink.macros)
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(entry.snapshot.totals.kcal))")
                    .font(.title2.bold().monospacedDigit())
                Text("/ \(entry.snapshot.kcalTarget ?? 0) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            progressBar(
                current: entry.snapshot.totals.kcal,
                target: entry.snapshot.kcalTarget,
                color: .orange
            )
            HStack(spacing: 6) {
                compactMacro("P", entry.snapshot.totals.protein, entry.snapshot.proteinTarget, .red)
                compactMacro("C", entry.snapshot.totals.carbs, entry.snapshot.carbsTarget, .green)
                compactMacro("G", entry.snapshot.totals.fat, entry.snapshot.fatTarget, .yellow)
            }
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 14) {
                macroRow("Calorias", entry.snapshot.totals.kcal, entry.snapshot.kcalTarget, "kcal", .orange)
                macroRow("Proteina", entry.snapshot.totals.protein, entry.snapshot.proteinTarget, "g", .red)
            }
            HStack(spacing: 14) {
                macroRow("Carbohidratos", entry.snapshot.totals.carbs, entry.snapshot.carbsTarget, "g", .green)
                macroRow("Grasas", entry.snapshot.totals.fat, entry.snapshot.fatTarget, "g", .yellow)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Macros", systemImage: "chart.pie.fill")
                .font(.headline)
            Spacer()
            Link(destination: WidgetLink.newMeal) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .accessibilityLabel("Anadir comida")
            }
        }
    }

    private func compactMacro(
        _ label: String,
        _ current: Double,
        _ target: Int?,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(color)
            Text("\(Int(current))/\(target ?? 0)")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macroRow(
        _ label: String,
        _ current: Double,
        _ target: Int?,
        _ unit: String,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(current))/\(target ?? 0) \(unit)")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            progressBar(current: current, target: target, color: color)
        }
        .frame(maxWidth: .infinity)
    }

    private func progressBar(current: Double, target: Int?, color: Color) -> some View {
        let value = target.flatMap { $0 > 0 ? min(current / Double($0), 1) : nil } ?? 0
        return ProgressView(value: value)
            .tint(color)
    }
}
