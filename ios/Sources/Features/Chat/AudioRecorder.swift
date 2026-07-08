// ============================================================
// AudioRecorder - grabación de audio con AVAudioRecorder.
//
// Formato: WAV (PCM 16-bit, 16kHz, mono) para máxima
// compatibilidad con el endpoint OpenAI de Gemini
// (input_audio format:"wav").
//
// Metering: isMeteringEnabled + averagePower(forChannel: 0)
// para alimentar la waveform estilo WhatsApp.
//
// Límite de duración: 3 minutos (180s). A 16kHz mono 16-bit
// eso son ~5.8MB (~7.7MB en base64), dentro del límite de
// 20MB de Gemini para audio inline.
// ============================================================

import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var audioData: Data?
    @Published var errorMessage: String?
    /// Nivel suavizado 0...1 para la waveform (suavizado exponencial).
    @Published var smoothedLevel: CGFloat = 0
    /// Jitters por barra para movimiento natural de la waveform.
    @Published var barJitters: [CGFloat] = Array(repeating: 0, count: 28)
    /// Segundos transcurridos en la grabacion actual.
    @Published var elapsedSeconds: TimeInterval = 0

    static let maxDurationSeconds: TimeInterval = 180  // 3 minutos

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var meteringTimer: Timer?
    private var elapsedTimer: Timer?

    func startRecording() {
        errorMessage = nil
        audioData = nil
        smoothedLevel = 0
        barJitters = Array(repeating: 0, count: 28)
        elapsedSeconds = 0

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorMessage = "No se pudo configurar audio: \(error.localizedDescription)"
            return
        }

        let filename = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutricoach-\(UUID().uuidString).wav")
        audioURL = filename

        // WAV: PCM lineal 16-bit little-endian, 16kHz, mono.
        // Sin compresión (PCM puro) para máxima compatibilidad con
        // input_audio format:"wav" del endpoint OpenAI de Gemini.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            recorder = try AVAudioRecorder(url: filename, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            isRecording = true
            startMeteringTimers()
        } catch {
            errorMessage = "No se pudo grabar: \(error.localizedDescription)"
        }
    }

    /// Detiene la grabacion y lee el audio del disco.
    /// CRITICO: es async porque AVAudioRecorder.stop() es asincrono:
    /// el archivo WAV no esta garantizado de estar flushed en disco
    /// inmediatamente despues de stop(). Si leemos con
    /// Data(contentsOf:) justo despues, podemos obtener un archivo
    /// incompleto o vacio -> Gemini no recibe audio valido.
    /// Esperamos 100ms (suficiente para PCM lineal) antes de leer.
    func stopRecording() async {
        recorder?.stop()
        isRecording = false
        stopMeteringTimers()

        guard let url = audioURL else { return }

        do {
            // Pequeno retardo para asegurar que AVAudioRecorder ha
            // hecho flush del archivo WAV a disco.
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            audioData = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            errorMessage = "No se pudo leer el audio: \(error.localizedDescription)"
        }
        audioURL = nil
    }

    func cancelRecording() {
        recorder?.stop()
        isRecording = false
        stopMeteringTimers()
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioURL = nil
        audioData = nil
        smoothedLevel = 0
        barJitters = Array(repeating: 0, count: 28)
        elapsedSeconds = 0
    }

    /// Nivel de audio instantáneo normalizado a 0...1.
    /// dB van de -160 (silencio) a 0 (pico). Normalizamos a 0...1.
    func currentLevel() -> Float {
        guard isRecording else { return 0 }
        recorder?.updateMeters()
        let power = recorder?.averagePower(forChannel: 0) ?? -160
        // power: -160..0 dB. Mapeamos -60..0 a 0..1 (silencio real por debajo de -60).
        let normalized = max(0, min(1, (power + 60) / 60))
        return normalized
    }

    // MARK: - Timers

    private func startMeteringTimers() {
        // Timer de muestreo de nivel (50ms) para la waveform.
        // Modo .common para que no se pause durante scroll/touch.
        let mTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                let rawLevel = self.currentLevel()
                // Suavizado exponencial: alpha alto = mas responsivo,
                // alpha bajo = mas suave. 0.3 da un movimiento fluido
                // estilo WhatsApp sin saltos bruscos.
                let alpha: CGFloat = 0.3
                self.smoothedLevel = (alpha * CGFloat(rawLevel)) + ((1 - alpha) * self.smoothedLevel)
                // Generar jitters suaves por barra para movimiento natural
                var newJitters: [CGFloat] = []
                for _ in 0..<28 {
                    newJitters.append(CGFloat.random(in: -0.12...0.12))
                }
                self.barJitters = newJitters
            }
        }
        RunLoop.main.add(mTimer, forMode: .common)
        meteringTimer = mTimer

        // Timer de elapsed (1s) para el contador y límite de 3 min.
        let eTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                if self.elapsedSeconds >= Self.maxDurationSeconds {
                    Task { await self.stopRecording() }
                }
            }
        }
        RunLoop.main.add(eTimer, forMode: .common)
        elapsedTimer = eTimer
    }

    private func stopMeteringTimers() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}