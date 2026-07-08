// ============================================================
// ChatInputBar - barra de entrada de chat estilo Claude.
//
// Tema visual oscuro (carbón #1a1a1a) sin gradientes. El input es
// un contenedor con esquinas muy redondeadas (radius ~28), fondo
// #2a2a2a, sin bordes. Una sola fila de altura fija:
//   [+]  [campo de texto........]  [micro <-> enviar]
//
// El botón de la derecha cambia de estado con transición de
// deslizamiento horizontal (~220ms ease-out) + fade:
//   - Vacío: círculo blanco con micro negro/gris.
//   - Con texto: círculo verde (#22c55e) con flecha arriba.
// ============================================================

import SwiftUI

struct ChatInputBar: View {
    /// Texto del campo (binding bidireccional con la vista padre).
    @Binding var text: String
    /// Placeholder del campo.
    var placeholder: String = "Chatear con Claude"
    /// True cuando el agente está procesando (deshabilita el envío).
    var isAgentThinking: Bool = false
    /// True cuando hay audio grabándose (deshabilita el envío).
    var isRecordingAudio: Bool = false
    /// Se invoca al pulsar el botón "+".
    var onPlusTap: () -> Void
    /// Se invoca al pulsar el botón de micrófono.
    var onMicTap: () -> Void
    /// Se invoca al pulsar el botón de enviar.
    var onSend: () -> Void

    /// Foco del campo de texto (lo controla la vista padre).
    var isFocused: FocusState<Bool>.Binding

    private let inputFondo = Color(red: 0.16, green: 0.16, blue: 0.16)   // #2a2a2a aprox
    private let textoClaro = Color(red: 0.90, green: 0.90, blue: 0.90)   // #e5e5e5
    private let grisMedio = Color(red: 0.54, green: 0.54, blue: 0.54)    // #8a8a8a
    private let verdeEnvío = Color(red: 0.13, green: 0.77, blue: 0.37)   // #22c55e

    private var tieneTexto: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            // Botón "+"
            Button(action: onPlusTap) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(textoClaro)
                    .frame(width: 38, height: 38)
            }
            .disabled(isAgentThinking)
            .accessibilityLabel("Abrir opciones")

            // Campo de texto
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(grisMedio)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .focused(isFocused)
                    .foregroundStyle(textoClaro)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { onSend() }
                    .disabled(isAgentThinking || isRecordingAudio)
                    .tint(verdeEnvío)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 14)

            // Botón de la derecha: micro <-> enviar con transición deslizante
            rightButton
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(inputFondo)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.22), value: tieneTexto)
        .animation(.easeInOut(duration: 0.2), value: isAgentThinking)
        .animation(.easeInOut(duration: 0.2), value: isRecordingAudio)
    }

    // MARK: - Botón derecho con transición deslizante

    @ViewBuilder
    private var rightButton: some View {
        ZStack {
            // Estado vacío: micrófono (círculo blanco, icono oscuro)
            if !tieneTexto {
                micButton
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
            // Estado con texto: enviar (círculo verde, flecha arriba)
            if tieneTexto {
                sendButton
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
        }
        // Recorta el deslizamiento para que el botón "entre desde detrás"
        .clipShape(Circle())
    }

    private var micButton: some View {
        Button(action: onMicTap) {
            Circle()
                .fill(Color.white)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.18, green: 0.18, blue: 0.18))
                )
        }
        .disabled(isAgentThinking)
        .accessibilityLabel("Grabar audio")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Circle()
                .fill(verdeEnvío)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
                )
        }
        .disabled(isAgentThinking || isRecordingAudio || !tieneTexto)
        .accessibilityLabel("Enviar mensaje")
    }
}