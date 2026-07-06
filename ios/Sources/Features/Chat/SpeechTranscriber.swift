// ============================================================
// SpeechTranscriber - transcribe audio a texto con SFSpeechRecognizer
// ============================================================
//
// MiniMax-M3 no soporta audio nativo, asi que transcribimos
// el audio del usuario a texto con el Speech framework de Apple
// y enviamos el texto al agente. El usuario ve su audio como
// un mensaje de texto en el chat.

import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published var isTranscribing = false
    @Published var transcribedText: String?
    @Published var errorMessage: String?

    func transcribe(audioURL: URL) async -> String? {
        isTranscribing = true
        errorMessage = nil
        transcribedText = nil
        defer { isTranscribing = false }

        // Pedir permiso de reconocimiento de voz
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted {
                errorMessage = "No se ha concedido permiso de reconocimiento de voz"
                return nil
            }
        } else if authStatus != .authorized {
            errorMessage = "Reconocimiento de voz no autorizado. Activalo en Ajustes > Privacidad > Reconocimiento de voz."
            return nil
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")) else {
            errorMessage = "No se pudo iniciar el reconocedor de voz"
            return nil
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            errorMessage = "Archivo de audio no encontrado"
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
                recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let result, result.isFinal {
                        continuation.resume(returning: result)
                    }
                }
            }
            let text = result.bestTranscription.formattedString
            transcribedText = text
            return text
        } catch {
            errorMessage = "Error transcribiendo: \(error.localizedDescription)"
            return nil
        }
    }
}