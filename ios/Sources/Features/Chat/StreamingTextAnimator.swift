import QuartzCore
import SwiftUI

private final class StreamingDisplayLinkTarget: NSObject {
    weak var animator: StreamingTextAnimator?

    init(animator: StreamingTextAnimator) {
        self.animator = animator
    }

    @objc func advance(_ link: CADisplayLink) {
        animator?.advanceFrame(link)
    }
}

struct StreamingTextFrame: Equatable {
    var stableText: String
    var appearingText: String
    var isComplete: Bool
    var revision: Int
}

final class StreamingTextAnimator: NSObject, ObservableObject {
    @Published private(set) var frame: StreamingTextFrame

    private var targetText: String
    private var targetCharacters: [Character]
    private var visibleCount: Int
    private var isReceiving: Bool
    private var reduceMotion = false
    private var displayLink: CADisplayLink?
    private lazy var displayLinkTarget = StreamingDisplayLinkTarget(animator: self)
    private var lastTimestamp: CFTimeInterval?
    private var characterAccumulator = 0.0
    private var caughtUpAt: CFTimeInterval?

    init(text: String, isStreaming: Bool) {
        targetText = text
        targetCharacters = Array(text)
        isReceiving = isStreaming
        if isStreaming {
            visibleCount = 0
            frame = StreamingTextFrame(
                stableText: "",
                appearingText: "",
                isComplete: false,
                revision: 0
            )
        } else {
            visibleCount = targetCharacters.count
            frame = StreamingTextFrame(
                stableText: text,
                appearingText: "",
                isComplete: true,
                revision: 0
            )
        }
        super.init()
    }

    deinit {
        displayLink?.invalidate()
    }

    func update(text: String, isStreaming: Bool, reduceMotion: Bool) {
        let visibleText = frame.stableText + frame.appearingText
        if !text.hasPrefix(visibleText) {
            visibleCount = 0
            frame = StreamingTextFrame(
                stableText: "",
                appearingText: "",
                isComplete: false,
                revision: frame.revision + 1
            )
        }

        targetText = text
        targetCharacters = Array(text)
        isReceiving = isStreaming
        self.reduceMotion = reduceMotion

        if reduceMotion {
            finishImmediately()
        } else if !frame.isComplete || isStreaming {
            startDisplayLinkIfNeeded()
        }
    }

    func pause() {
        stopDisplayLink()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(
            target: displayLinkTarget,
            selector: #selector(StreamingDisplayLinkTarget.advance(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        characterAccumulator = 0
        caughtUpAt = nil
    }

    private func finishImmediately() {
        visibleCount = targetCharacters.count
        frame = StreamingTextFrame(
            stableText: targetText,
            appearingText: "",
            isComplete: !isReceiving,
            revision: frame.revision + 1
        )
        stopDisplayLink()
    }

    fileprivate func advanceFrame(_ link: CADisplayLink) {
        if reduceMotion {
            finishImmediately()
            return
        }

        let frameDuration = lastTimestamp.map {
            min(max(link.timestamp - $0, 1.0 / 240.0), 1.0 / 20.0)
        } ?? link.duration
        lastTimestamp = link.timestamp

        // El ultimo grafema queda provisional mientras llegan deltas: puede
        // recibir una tilde combinada, un modificador o una secuencia ZWJ.
        let revealableCount = isReceiving
            ? max(targetCharacters.count - 1, 0)
            : targetCharacters.count
        let backlog = revealableCount - visibleCount
        guard backlog > 0 else {
            if isReceiving {
                stopDisplayLink()
            } else {
                settleIfFinished(at: link.timestamp)
            }
            return
        }

        caughtUpAt = nil
        let adaptiveRate = min(360.0, 150.0 + Double(backlog) * 5.0)
        characterAccumulator += adaptiveRate * frameDuration
        let available = Int(characterAccumulator)
        guard available > 0 else { return }

        // Mantener lotes diminutos evita que un chunk de red vuelva a aparecer
        // como un bloque, incluso cuando hay mucho texto pendiente.
        let count = min(backlog, min(3, available))
        characterAccumulator -= Double(count)
        let end = visibleCount + count
        let newCharacters = String(targetCharacters[visibleCount..<end])
        let previousText = frame.stableText + frame.appearingText
        visibleCount = end
        frame = StreamingTextFrame(
            stableText: previousText,
            appearingText: newCharacters,
            isComplete: false,
            revision: frame.revision + 1
        )
    }

    private func settleIfFinished(at timestamp: CFTimeInterval) {
        guard !isReceiving else { return }
        if caughtUpAt == nil {
            caughtUpAt = timestamp
            return
        }
        guard timestamp - (caughtUpAt ?? timestamp) >= 0.08 else { return }

        frame = StreamingTextFrame(
            stableText: targetText,
            appearingText: "",
            isComplete: true,
            revision: frame.revision + 1
        )
        stopDisplayLink()
    }
}
