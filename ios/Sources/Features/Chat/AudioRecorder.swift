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
    /// Niveles de audio normalizados 0...1 para la waveform.
    @Published var levels: [CGFloat] = []
    /// Segundos transcurridos en la grabación actual.
    @Published var elapsedSeconds: TimeInterval = 0

    static let maxDurationSeconds: TimeInterval = 180  // 3 minutos

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var meteringTimer: Timer?
    private var elapsedTimer: Timer?

    func startRecording() {
        errorMessage = nil
        audioData = nil
        levels = []
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

    func stopRecording() {
        recorder?.stop()
        isRecording = false
        stopMeteringTimers()

        guard let url = audioURL else { return }
        do {
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
        levels = []
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
        // Timer de muestreo de nivel (100ms) para la waveform.
        // Modo .common para que no se pause durante scroll/touch.
        let mTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                let level = self.currentLevel()
                self.levels.append(CGFloat(level))
                // Mantener solo las últimas 40 muestras (4s de histórico visible)
                if self.levels.count > 40 {
                    self.levels.removeFirst(self.levels.count - 40)
                }
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
                    self.stopRecording()
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