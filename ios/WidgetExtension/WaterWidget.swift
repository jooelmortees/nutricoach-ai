import SwiftUI
import WidgetKit

struct WaterWidget: Widget {
    static let kind = "com.joelmortees.nutricoach.water"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DailyTrackingProvider()) { entry in
            WaterWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Agua de hoy")
        .description("Muestra tu hidratacion y registra un vaso sin abrir la app.")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Agua", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.snapshot.waterMl)")
                    .font(.title2.bold().monospacedDigit())
                Text("/ \(entry.snapshot.waterTargetMl) ml")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(value: progress)
                .tint(.cyan)

            if let userId = entry.snapshot.userId {
                HStack(spacing: 8) {
                    waterButton(amountMl: 250, userId: userId)
                    if family == .systemMedium {
                        waterButton(amountMl: 500, userId: userId)
                    }
                }
            } else {
                Text("Abre NutriCoach para iniciar sesion")
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
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
    }
}
