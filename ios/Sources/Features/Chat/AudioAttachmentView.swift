import AVFoundation
import SwiftUI

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var legacyFiles: [UUID: URL] = [:]

    func toggle(
        id: UUID,
        remoteURL: String? = nil,
        localURL: URL? = nil,
        legacyBase64: String? = nil
    ) {
        if activeID == id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }

        guard let url = playbackURL(
            id: id,
            remoteURL: remoteURL,
            localURL: localURL,
            legacyBase64: legacyBase64
        ) else {
            errorMessage = "No se pudo abrir este audio."
            return
        }

        replacePlayer(with: url, id: id)
    }

    func isPlaying(id: UUID) -> Bool {
        activeID == id && isPlaying
    }

    func progress(id: UUID, duration: TimeInterval) -> Double {
        guard activeID == id, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func stop() {
        player?.pause()
        removeObservers()
        player = nil
        activeID = nil
        isPlaying = false
        currentTime = 0
    }

    private func playbackURL(
        id: UUID,
        remoteURL: String?,
        localURL: URL?,
        legacyBase64: String?
    ) -> URL? {
        if let localURL { return localURL }
        if let remoteURL, let url = URL(string: remoteURL) { return url }
        if let cached = legacyFiles[id] { return cached }
        guard let legacyBase64, let data = Data(base64Encoded: legacyBase64) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-audio-\(id.uuidString).wav")
        do {
            try data.write(to: url, options: .atomic)
            legacyFiles[id] = url
            return url
        } catch {
            errorMessage = "No se pudo preparar el audio: \(error.localizedDescription)"
            return nil
        }
    }

    private func replacePlayer(with url: URL, id: UUID) {
        stop()
        errorMessage = nil

        let player = AVPlayer(url: url)
        self.player = player
        activeID = id
        isPlaying = true
        currentTime = 0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                let seconds = time.seconds
                self?.currentTime = seconds.isFinite ? max(seconds, 0) : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                let underlyingError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.errorMessage = underlyingError.map { "No se pudo reproducir el audio: \($0.localizedDescription)" }
                    ?? "No se pudo reproducir el audio."
                self?.isPlaying = false
            }
        }
        player.play()
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
    }
}

struct AudioAttachmentCard: View {
    let id: UUID
    let title: String
    let duration: TimeInterval
    let sizeBytes: Int
    var remoteURL: String?
    var localURL: URL?
    var legacyBase64: String?
    var onRemove: (() -> Void)?
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Button {
                    playback.toggle(
                        id: id,
                        remoteURL: remoteURL,
                        localURL: localURL,
                        legacyBase64: legacyBase64
                    )
                } label: {
                    Image(systemName: playback.isPlaying(id: id) ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.green, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying(id: id) ? "Pausar audio" : "Reproducir audio")

                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(formatDuration(duration)) · \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Descartar audio")
                }
            }

            ProgressView(value: playback.progress(id: id, duration: duration))
                .tint(.green)
                .frame(height: 2)
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
