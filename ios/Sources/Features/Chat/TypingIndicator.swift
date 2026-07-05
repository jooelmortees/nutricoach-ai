// ============================================================
// TypingIndicator - 3 puntos animados estilo ChatGPT
// ============================================================

import SwiftUI

struct TypingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(scaleForDot(i))
                    .opacity(opacityForDot(i))
            }
        }
        .frame(width: 44, height: 24, alignment: .center)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private func scaleForDot(_ index: Int) -> CGFloat {
        let delay = Double(index) * 0.2
        let t = (Double(phase) - delay).truncatingRemainder(dividingBy: 1.0)
        return t >= 0 && t < 0.4 ? 1.3 : 0.8
    }

    private func opacityForDot(_ index: Int) -> Double {
        let delay = Double(index) * 0.2
        let t = (Double(phase) - delay).truncatingRemainder(dividingBy: 1.0)
        return t >= 0 && t < 0.4 ? 1.0 : 0.4
    }
}