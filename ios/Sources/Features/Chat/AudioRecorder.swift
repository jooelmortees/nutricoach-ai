// ============================================================
// AudioRecorder - grabacion de audio con AVAudioRecorder
// Incluye niveles de amplitud para waveform visual en tiempo real
// ============================================================

import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var audioURL: URL?
    @Published var errorMessage: String?
    @Published var amplitude: CGFloat = 0
    @Published var duration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func startRecording() {
        errorMessage = nil
        audioURL = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorMessage = "No se pudo configurar audio: \(error.localizedDescription)"
            return
        }

        let filename = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutricoach-\(UUID().uuidString).m4a")
        audioURL = filename

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            recorder = try AVAudioRecorder(url: filename, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            isRecording = true
            startMeterTimer()
        } catch {
            errorMessage = "No se pudo grabar: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        isRecording = false
        amplitude = 0
    }

    func cancelRecording() {
        stopRecording()
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioURL = nil
        duration = 0
    }

    private func startMeterTimer() {
        duration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let rawAmplitude = recorder.averagePower(forChannel: 0)
            // Convertir dBFS (-160..0) a 0..1
            let normalized = CGFloat(max(0, (rawAmplitude + 160) / 160))
            DispatchQueue.main.async {
                self.amplitude = normalized
                self.duration += 0.05
            }
        }
    }
}