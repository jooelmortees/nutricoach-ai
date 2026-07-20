import SwiftUI
import WidgetKit

struct WaterWidget: Widget {
    static let kind = NutriCoachWidgetKind.water

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DailyTrackingProvider()) { entry in
            WaterWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Agua de hoy")
        .description("Muestra tu hidratación y registra un vaso sin abrir la app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct WaterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyTrackingEntry

    private var progress: Double {
        guard entry.snapshot.waterTargetMl > 0 else { return 0 }
        return min(
            Double(entry.snapshot.waterMl) / Double(entry.snapshot.waterTargetMl),
            1
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Agua", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                if entry.snapshot.waterSyncErrorAt != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("No se pudo guardar la última cantidad de agua")
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.snapshot.waterMl)")
                    .font(.title2.bold().monospacedDigit())
                Text("/ \(entry.snapshot.waterTargetMl) ml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .invalidatableContent()

            ProgressView(value: progress)
                .tint(.cyan)
                .invalidatableContent()
                .accessibilityLabel("Progreso de agua")
                .accessibilityValue("\(entry.snapshot.waterMl) de \(entry.snapshot.waterTargetMl) mililitros")

            if let userId = entry.snapshot.userId {
                HStack(spacing: 8) {
                    waterButton(amountMl: 250, userId: userId)
                    if family == .systemMedium {
                        waterButton(amountMl: 500, userId: userId)
                    }
                }
            } else {
                Text("Abre NutriCoach para iniciar sesión")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .widgetURL(WidgetLink.macros)
    }

    private func waterButton(amountMl: Int, userId: UUID) -> some View {
        Button(intent: LogWaterIntent(amountMl: amountMl, userId: userId)) {
            Label("\(amountMl) ml", systemImage: "plus")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, minHeight: 34)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .accessibilityLabel("Añadir \(amountMl) mililitros de agua")
    }
}
