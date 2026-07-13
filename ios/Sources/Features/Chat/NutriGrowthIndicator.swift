import SwiftUI

struct NutriGrowthIndicator: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                nutritionPlate(
                    rotation: .degrees(elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8 * 360),
                    pulse: 1 + sin(elapsed * 4) * 0.035
                )
            }
        } else {
            nutritionPlate(rotation: .zero, pulse: 1)
        }
    }

    private func nutritionPlate(rotation: Angle, pulse: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.green.opacity(0.1))
                .overlay {
                    Circle()
                        .stroke(Color.green.opacity(0.28), lineWidth: 1)
                }

            Image(systemName: "fork.knife")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.green)

            if isActive {
                Circle()
                    .trim(from: 0, to: 0.24)
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(rotation)
                    .padding(1)
            } else {
                Circle()
                    .stroke(Color.orange.opacity(0.45), lineWidth: 1.5)
                    .padding(2)
            }

            Image(systemName: "leaf.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 13, height: 13)
                .background(Color.green, in: Circle())
                .offset(x: 3, y: -3)
        }
        .scaleEffect(pulse)
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}
