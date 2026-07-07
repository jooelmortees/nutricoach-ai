// ============================================================
// AudioRecorder - grabacion de audio con AVAudioRecorder
// ============================================================

import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var audioData: Data?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?

    func startRecording() {
        errorMessage = nil
        audioData = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorMessage = "No se pudo configurar audio: \(error.localizedDescription)"
            return
        }

        let filename = FileManager.default.temporaryDirectory.appendingPathComponent("nutricoach-\(UUID().uuidString).m4a")
        audioURL = filename

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            recorder = try AVAudioRecorder(url: filename, settings: settings)
            recorder?.record()
            isRecording = true
        } catch {
            errorMessage = "No se pudo grabar: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recorder?.stop()
        isRecording = false

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
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioURL = nil
        audioData = nil
    }
}