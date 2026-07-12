import SwiftUI

struct NutriGrowthIndicator: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isActive && !reduceMotion {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    sprout(phase: phase)
                } animation: { phase in
                    if phase == 1 || phase == 2 {
                        return .easeOut(duration: 0.32)
                    }
                    return .easeInOut(duration: 0.38)
                }
            } else {
                sprout(phase: 3)
            }
        }
        .frame(width: 30, height: 34)
        .accessibilityHidden(true)
    }

    private func sprout(phase: Int) -> some View {
        ZStack {
            Capsule()
                .fill(Color.green)
                .frame(width: 3, height: 17)
                .scaleEffect(y: phase == 0 ? 0.35 : 1, anchor: .bottom)
                .offset(y: 6)

            Capsule()
                .fill(Color.green.opacity(0.85))
                .frame(width: 11, height: 6)
                .rotationEffect(.degrees(-32), anchor: .trailing)
                .scaleEffect(phase >= 2 ? 1 : 0.2, anchor: .trailing)
                .offset(x: -5, y: -1)

            Capsule()
                .fill(Color.teal.opacity(0.9))
                .frame(width: 11, height: 6)
                .rotationEffect(.degrees(32), anchor: .leading)
                .scaleEffect(phase >= 3 ? 1 : 0.2, anchor: .leading)
                .offset(x: 5, y: -5)

            Capsule()
                .fill(Color.orange)
                .frame(width: 3, height: 5)
                .offset(y: phase == 0 ? 11 : -6)
                .opacity(isActive ? 0.9 : 0)
        }
    }
}
