// ============================================================
// ChatInputBar - barra de entrada de chat estilo Claude.
//
// Tema visual oscuro (carbón #1a1a1a) sin gradientes. El input es
// un contenedor con esquinas muy redondeadas (radius ~28), fondo
// #2a2a2a, sin bordes.
//
// Layout normal (una fila):
//   [+]  [campo de texto........]  [micro] [enviar]
//
// Modo grabación (al pulsar el micro y empezar a grabar):
//   [X]  [waveform + contador]              [stop+enviar]
//
// - El botón "+" abre el PlusMenuSheet (cámara/galería/búsqueda web).
// - El micrófono inicia/detiene la grabación (NO envía solo).
// - El enviar: si hay texto/audio listo/adjuntos envía; si está
//   grabando, para la grabación y envía el audio.
// ============================================================

import SwiftUI

struct ChatInputBar: View {
    /// Texto del campo (binding bidireccional con la vista padre).
    @Binding var text: String
    /// Placeholder del campo.
    var placeholder: String = "Chatear con Claude"
    /// True cuando el agente está procesando (deshabilita el envío).
    var isAgentThinking: Bool = false
    /// True cuando hay audio grabándose (modo grabación activo).
    var isRecordingAudio: Bool = false
    /// True cuando hay un audio ya grabado listo para enviar.
    var hasReadyAudio: Bool = false
    /// True cuando hay imágenes adjuntas pendientes.
    var hasAttachments: Bool = false
    /// Recorder observable para alimentar la waveform y el contador.
    @ObservedObject var recorder: AudioRecorder
    /// Se invoca al pulsar el botón "+".
    var onPlusTap: () -> Void
    /// Se invoca al pulsar el botón de micrófono (inicia grabación).
    var onMicTap: () -> Void
    /// Se invoca al pulsar cancelar grabación.
    var onCancelRecording: () -> Void
    /// Se invoca al pulsar el botón de enviar (o stop+enviar si grabando).
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

    private var canSend: Bool {
        (tieneTexto || hasReadyAudio || hasAttachments) && !isAgentThinking && !isRecordingAudio
    }

    var body: some View {
        if isRecordingAudio {
            recordingBar
        } else {
            normalBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.22), value: isRecordingAudio)
        .animation(.easeInOut(duration: 0.2), value: isAgentThinking)
        .animation(.easeInOut(duration: 0.2), value: hasReadyAudio)
    }

    // MARK: - Barra normal

    private var normalBar: some View {
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

            // Campo de texto (o indicador de audio listo)
            if hasReadyAudio {
                audioReadyIndicator
            } else {
                textField
            }

            // Botón micrófono (fijo, a la izquierda del enviar)
            micButton
                .frame(width: 40, height: 40)

            // Botón enviar
            sendButton
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(inputFondo)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var textField: some View {
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
                .onSubmit { if canSend { onSend() } }
                .disabled(isAgentThinking)
                .tint(verdeEnvío)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 14)
    }

    private var audioReadyIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(verdeEnvío)
            Text("Audio listo")
                .font(.subheadline)
                .foregroundStyle(textoClaro)
            Spacer()
            Button {
                recorder.audioData = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(grisMedio)
            }
            .accessibilityLabel("Descartar audio")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 14)
    }

    // MARK: - Barra de grabación

    private var recordingBar: some View {
        HStack(spacing: 10) {
            // Botón cancelar (X)
            Button(action: onCancelRecording) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(grisMedio)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Cancelar grabación")

            // Punto rojo pulsante
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .symbolEffect(.pulse, options: .repeating, isActive: isRecordingAudio)

            // Waveform + contador
            AudioWaveform(recorder: recorder)
                .frame(maxWidth: .infinity)

            Text(formatTime(recorder.elapsedSeconds))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(textoClaro)

            // Botón stop+enviar
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
            .accessibilityLabel("Detener y enviar audio")
            .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(inputFondo)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    // MARK: - Botones

    private var micButton: some View {
        Button(action: onMicTap) {
            Circle()
                .fill(hasReadyAudio ? Color.white.opacity(0.15) : Color.white)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: hasReadyAudio ? "checkmark" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hasReadyAudio ? textoClaro : Color(red: 0.18, green: 0.18, blue: 0.18))
                )
        }
        .disabled(isAgentThinking)
        .accessibilityLabel(hasReadyAudio ? "Audio grabado" : "Grabar audio")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Circle()
                .fill(canSend ? verdeEnvío : Color.white.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(canSend ? Color(red: 0.12, green: 0.12, blue: 0.12) : grisMedio)
                )
        }
        .disabled(!canSend)
        .accessibilityLabel("Enviar mensaje")
    }

    // MARK: - Utilidades

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}