// ============================================================
// AudioWaveform - visualizacion de barras estilo WhatsApp.
//
// Barras finas blancas con suavizado temporal. El nivel del
// microfono se muestrea cada 50ms y se suaviza exponencialmente
// para evitar saltos bruscos. Las barras centrales son mas altas
// y las de los bordes mas bajas, creando un patron de onda natural.
// ============================================================

import SwiftUI

struct AudioWaveform: View {
    @ObservedObject var recorder: AudioRecorder

    private let barCount: Int = 28
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2.5
    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(opacity(for: index)))
                    .frame(width: barWidth, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.08), value: recorder.smoothedLevel)
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
    }

    /// Altura de cada barra: combina el nivel suavizado con un patron
    /// de pico central (las barras del centro son mas altas) y un jitter
    /// aleatorio suave para dar movimiento natural.
    private func barHeight(for index: Int) -> CGFloat {
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let peakFactor = 1.0 - (distance * 0.5)

        let level = recorder.smoothedLevel
        let jitter: CGFloat = index < recorder.barJitters.count ? recorder.barJitters[index] : 0
        let effectiveLevel = level * peakFactor * (1.0 + jitter)

        let height = minBarHeight + (maxBarHeight - minBarHeight) * effectiveLevel
        return max(minBarHeight, min(height, maxBarHeight))
    }

    /// Opacidad decreciente hacia los bordes para efecto mas limpio.
    private func opacity(for index: Int) -> Double {
        let center = Double(barCount) / 2.0
        let distance = abs(Double(index) - center) / center
        return 0.9 - (distance * 0.3)
    }
}