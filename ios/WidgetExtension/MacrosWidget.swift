import SwiftUI
import WidgetKit

struct MacrosWidget: Widget {
    static let kind = NutriCoachWidgetKind.macros

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DailyTrackingProvider()) { entry in
            MacrosWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Seguimiento diario")
        .description("Muestra tus macros y, en tamaño grande, permite registrar comida y agua.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct MacrosWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyTrackingEntry

    var body: some View {
        Group {
            if family == .systemLarge {
                largeView
            } else if family == .systemMedium {
                mediumView
            } else {
                smallView
            }
        }
        .widgetURL(WidgetLink.macros)
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(entry.snapshot.totals.kcal))")
                    .font(.title2.bold().monospacedDigit())
                Text("/ \(targetText(entry.snapshot.kcalTarget)) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            progressBar(
                current: entry.snapshot.totals.kcal,
                target: entry.snapshot.kcalTarget,
                color: .orange,
                label: "Calorías",
                unit: "kcal"
            )
            HStack(spacing: 6) {
                compactMacro("P", "Proteína", entry.snapshot.totals.protein, entry.snapshot.proteinTarget, .red)
                compactMacro("C", "Carbohidratos", entry.snapshot.totals.carbs, entry.snapshot.carbsTarget, .green)
                compactMacro("G", "Grasas", entry.snapshot.totals.fat, entry.snapshot.fatTarget, .yellow)
            }
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 14) {
                macroRow("Calorías", entry.snapshot.totals.kcal, entry.snapshot.kcalTarget, "kcal", .orange)
                macroRow("Proteína", entry.snapshot.totals.protein, entry.snapshot.proteinTarget, "g", .red)
            }
            HStack(spacing: 14) {
                macroRow("Carbos", entry.snapshot.totals.carbs, entry.snapshot.carbsTarget, "g", .green)
                    .accessibilityLabel("Carbohidratos")
                macroRow("Grasas", entry.snapshot.totals.fat, entry.snapshot.fatTarget, "g", .yellow)
            }
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(entry.snapshot.totals.kcal))")
                    .font(.title.bold().monospacedDigit())
                Text("de \(targetText(entry.snapshot.kcalTarget)) kcal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(kcalBalanceText)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            progressBar(
                current: entry.snapshot.totals.kcal,
                target: entry.snapshot.kcalTarget,
                color: .orange,
                label: "Calorías",
                unit: "kcal"
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 10
            ) {
                largeMacro(
                    "Proteína",
                    entry.snapshot.totals.protein,
                    entry.snapshot.proteinTarget,
                    .red
                )
                largeMacro(
                    "Carbos",
                    entry.snapshot.totals.carbs,
                    entry.snapshot.carbsTarget,
                    .green
                )
                largeMacro(
                    "Grasas",
                    entry.snapshot.totals.fat,
                    entry.snapshot.fatTarget,
                    .yellow
                )
            }

            Divider()

            HStack(spacing: 6) {
                Label("Agua", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                if entry.snapshot.waterSyncErrorAt != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("No se pudo guardar la última cantidad de agua")
                }
                Text("\(entry.snapshot.waterMl) / \(entry.snapshot.waterTargetMl) ml")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .invalidatableContent()

            ProgressView(value: waterProgress)
                .tint(.cyan)
                .invalidatableContent()
                .accessibilityLabel("Progreso de agua")
                .accessibilityValue("\(entry.snapshot.waterMl) de \(entry.snapshot.waterTargetMl) mililitros")

            HStack(spacing: 8) {
                Link(destination: WidgetLink.newMeal) {
                    Label("Comida", systemImage: "plus")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityLabel("Añadir comida")

                if let userId = entry.snapshot.userId {
                    waterButton(amountMl: 250, userId: userId)
                    waterButton(amountMl: 500, userId: userId)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label(
                family == .systemLarge ? "Macros y agua" : "Macros",
                systemImage: "chart.pie.fill"
            )
                .font(.headline)
            Spacer()
            if family == .systemLarge {
                Text("Hoy")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            } else {
                Link(destination: WidgetLink.newMeal) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Añadir comida")
                }
            }
        }
    }

    private var kcalBalanceText: String {
        guard let target = entry.snapshot.kcalTarget else { return "Sin objetivo" }
        let difference = target - Int(entry.snapshot.totals.kcal)
        return difference >= 0
            ? "\(difference) restantes"
            : "\(abs(difference)) por encima"
    }

    private var waterProgress: Double {
        guard entry.snapshot.waterTargetMl > 0 else { return 0 }
        return min(
            Double(entry.snapshot.waterMl) / Double(entry.snapshot.waterTargetMl),
            1
        )
    }

    private func compactMacro(
        _ label: String,
        _ fullLabel: String,
        _ current: Double,
        _ target: Int?,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(color)
            Text("\(Int(current))/\(targetText(target))")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fullLabel)
        .accessibilityValue(
            macroAccessibilityValue(current: current, target: target, unit: "gramos")
        )
    }

    private func macroRow(
        _ label: String,
        _ current: Double,
        _ target: Int?,
        _ unit: String,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(current))/\(targetText(target)) \(unit)")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            progressBar(
                current: current,
                target: target,
                color: color,
                label: label,
                unit: unit
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func largeMacro(
        _ label: String,
        _ current: Double,
        _ target: Int?,
        _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(Int(current))/\(targetText(target)) g")
                .font(.caption2.bold().monospacedDigit())
                .lineLimit(1)
            progressBar(
                current: current,
                target: target,
                color: color,
                label: label == "Carbos" ? "Carbohidratos" : label,
                unit: "g"
            )
        }
    }

    private func waterButton(amountMl: Int, userId: UUID) -> some View {
        Button(intent: LogWaterIntent(amountMl: amountMl, userId: userId)) {
            Label("\(amountMl) ml", systemImage: "plus")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, minHeight: 34)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered)
        .tint(.cyan)
        .accessibilityLabel("Añadir \(amountMl) mililitros de agua")
    }

    private func progressBar(
        current: Double,
        target: Int?,
        color: Color,
        label: String,
        unit: String
    ) -> some View {
        let value = target.flatMap { $0 > 0 ? min(current / Double($0), 1) : nil } ?? 0
        return ProgressView(value: value)
            .tint(color)
            .accessibilityLabel(Text(label))
            .accessibilityValue(
                Text(macroAccessibilityValue(current: current, target: target, unit: unit))
            )
    }

    private func targetText(_ target: Int?) -> String {
        target.map(String.init) ?? "--"
    }

    private func macroAccessibilityValue(
        current: Double,
        target: Int?,
        unit: String
    ) -> String {
        guard let target else {
            return "\(Int(current)) \(unit), sin objetivo"
        }
        return "\(Int(current)) de \(target) \(unit)"
    }
}
