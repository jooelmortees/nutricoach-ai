// ============================================================
// AudioWaveform - visualización de barras estilo WhatsApp que
// reaccionan al volumen real del micrófono durante la grabación.
//
// Se alimenta de AudioRecorder.levels (array de CGFloat 0...1)
// que se actualiza cada 100ms vía averagePower(forChannel:).
// ============================================================

import SwiftUI

struct AudioWaveform: View {
    @ObservedObject var recorder: AudioRecorder

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            // Renderizamos las muestras históricas (las más recientes a la derecha)
            ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.red)
                    .frame(width: barWidth, height: barHeight(for: level))
                    .animation(.easeOut(duration: 0.08), value: recorder.levels.count)
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
    }

    /// Mapea nivel 0...1 a altura de barra entre minBarHeight y maxBarHeight.
    private func barHeight(for level: CGFloat) -> CGFloat {
        let clamped = max(0.05, min(1, level))
        return minBarHeight + (maxBarHeight - minBarHeight) * clamped
    }
}