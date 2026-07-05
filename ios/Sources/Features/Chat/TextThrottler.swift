// ============================================================
// TextThrottler - frena las actualizaciones de UI durante streaming
// para que SwiftUI no congele en mensajes largos.
// Basado en el patron de Enchanted (gluonfield/enchanted).
// ============================================================
//
// Sin throttler: cada token del stream hace que SwiftUI re-render
// todo el LazyVStack, lo que congela la UI en mensajes >500 caracteres.
// Con throttler: acumulamos tokens en un buffer y los volcamos a la
// UI maximo 10 veces por segundo (cada 0.1s).

import Foundation

@MainActor
final class TextThrottler {
    private var buffer: String = ""
    private var workItem: DispatchWorkItem?
    private let interval: TimeInterval
    private let onFlush: (String) -> Void

    init(interval: TimeInterval = 0.08, onFlush: @escaping (String) -> Void) {
        self.interval = interval
        self.onFlush = onFlush
    }

    /// Anade texto al buffer. Si ha pasado suficiente tiempo desde
    /// el ultimo flush, vuelca el buffer a la UI.
    func append(_ text: String) {
        buffer += text
        scheduleFlush()
    }

    /// Fuerza el volcado inmediato del buffer (usar al terminar el stream).
    func flushNow() {
        workItem?.cancel()
        workItem = nil
        if !buffer.isEmpty {
            onFlush(buffer)
            buffer = ""
        }
    }

    private func scheduleFlush() {
        guard workItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.buffer.isEmpty {
                self.onFlush(self.buffer)
                self.buffer = ""
            }
            self.workItem = nil
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }
}