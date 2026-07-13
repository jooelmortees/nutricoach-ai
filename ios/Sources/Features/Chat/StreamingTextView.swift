import QuartzCore
import SwiftUI
import UIKit

final class StreamingUITextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct StreamingTextView: UIViewRepresentable {
    let text: String
    let isStreaming: Bool
    let reduceMotion: Bool
    @Binding var measuredHeight: CGFloat
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight, onFinished: onFinished)
    }

    func makeUIView(context: Context) -> StreamingUITextView {
        let textView = StreamingUITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(textView)
        textView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleHeightMeasurement()
        }
        return textView
    }

    func updateUIView(_ textView: StreamingUITextView, context: Context) {
        context.coordinator.measuredHeight = $measuredHeight
        context.coordinator.onFinished = onFinished
        context.coordinator.update(
            text: text,
            isStreaming: isStreaming,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleUIView(_ uiView: StreamingUITextView, coordinator: Coordinator) {
        uiView.onLayout = nil
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var measuredHeight: Binding<CGFloat>
        var onFinished: () -> Void

        private weak var textView: UITextView?
        private var targetText = ""
        private var targetCharacters: [Character] = []
        private var visibleCount = 0
        private var isReceiving = true
        private var reduceMotion = false
        private var didFinish = false
        private var displayLink: CADisplayLink?
        private lazy var displayLinkTarget = DisplayLinkTarget(coordinator: self)
        private var lastTimestamp: CFTimeInterval?
        private var characterAccumulator = 0.0
        private var caughtUpAt: CFTimeInterval?
        private var heightMeasurementTask: DispatchWorkItem?
        private var lastHeightMeasurementAt: CFTimeInterval = 0
        private var hasReceivedUpdate = false
        private var isAttached = false

        init(measuredHeight: Binding<CGFloat>, onFinished: @escaping () -> Void) {
            self.measuredHeight = measuredHeight
            self.onFinished = onFinished
        }

        func attach(_ textView: UITextView) {
            self.textView = textView
            isAttached = true
        }

        func update(text: String, isStreaming: Bool, reduceMotion: Bool) {
            guard let textView else { return }

            let isRestoring = !hasReceivedUpdate && measuredHeight.wrappedValue > 1
            updateTarget(with: text)
            hasReceivedUpdate = true
            self.isReceiving = isStreaming
            self.reduceMotion = reduceMotion

            if didFinish { return }

            if isRestoring && !text.isEmpty {
                let restoredCount = isStreaming
                    ? max(targetCharacters.count - 1, 0)
                    : targetCharacters.count
                replaceRenderedText(String(targetCharacters.prefix(restoredCount)))
                visibleCount = restoredCount
            }

            if reduceMotion {
                setCompleteText(text)
                if !isStreaming {
                    finish()
                }
                return
            }

            let revealableCount = isStreaming
                ? max(targetCharacters.count - 1, 0)
                : targetCharacters.count
            let backlog = revealableCount - visibleCount
            if !isStreaming && backlog > 1_000 {
                setCompleteText(text)
                finish()
                return
            }
            if visibleCount < revealableCount || !isStreaming {
                startDisplayLinkIfNeeded()
            }
            scheduleHeightMeasurement()
        }

        func detach() {
            isAttached = false
            heightMeasurementTask?.cancel()
            heightMeasurementTask = nil
            stop()
        }

        private func stop() {
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = nil
            characterAccumulator = 0
            caughtUpAt = nil
        }

        fileprivate func advanceFrame(_ link: CADisplayLink) {
            guard !reduceMotion, let textView else {
                stop()
                return
            }

            let frameDuration = lastTimestamp.map {
                min(max(link.timestamp - $0, 1.0 / 240.0), 1.0 / 20.0)
            } ?? link.duration
            lastTimestamp = link.timestamp

            // Reservar el ultimo grafema evita mostrar media tilde o un emoji
            // incompleto si el siguiente delta extiende esa secuencia.
            let revealableCount = isReceiving
                ? max(targetCharacters.count - 1, 0)
                : targetCharacters.count
            let backlog = revealableCount - visibleCount
            guard backlog > 0 else {
                if isReceiving {
                    stop()
                } else {
                    settleIfFinished(at: link.timestamp)
                }
                return
            }

            caughtUpAt = nil
            let adaptiveRate: Double
            let maximumBatch: Int
            if isReceiving {
                adaptiveRate = min(360.0, 150.0 + Double(backlog) * 5.0)
                maximumBatch = 3
            } else {
                adaptiveRate = min(2_400.0, max(600.0, Double(backlog) / 0.45))
                maximumBatch = 24
            }
            characterAccumulator += adaptiveRate * frameDuration
            let available = Int(characterAccumulator)
            guard available > 0 else { return }

            let count = min(backlog, min(maximumBatch, available))
            characterAccumulator -= Double(count)
            let end = visibleCount + count
            let suffix = String(targetCharacters[visibleCount..<end])
            visibleCount = end

            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
            textView.textStorage.append(NSAttributedString(string: suffix, attributes: attributes))
            scheduleHeightMeasurement()
        }

        private func setCompleteText(_ text: String) {
            visibleCount = targetCharacters.count
            replaceRenderedText(text)
            scheduleHeightMeasurement()
            stop()
        }

        private func updateTarget(with text: String) {
            guard text != targetText else { return }

            let previousByteCount = targetText.utf8.count
            // ChatViewModel solo concatena textDelta para un mismo mensaje.
            // Evitamos comparar todo el prefijo en cada delta: seria O(n²).
            if text.utf8.count >= previousByteCount {
                let suffixBytes = text.utf8.dropFirst(previousByteCount)
                let suffix = String(decoding: suffixBytes, as: UTF8.self)
                if !targetCharacters.isEmpty {
                    let provisional = String(targetCharacters.removeLast()) + suffix
                    targetCharacters.append(contentsOf: Array(provisional))
                } else {
                    targetCharacters.append(contentsOf: Array(suffix))
                }
            } else {
                targetCharacters = Array(text)
                visibleCount = 0
                replaceRenderedText("")
            }
            targetText = text
        }

        private func replaceRenderedText(_ text: String) {
            guard let textView, textView.text != text else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
            textView.textStorage.setAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(
                target: displayLinkTarget,
                selector: #selector(DisplayLinkTarget.advance(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func settleIfFinished(at timestamp: CFTimeInterval) {
            if caughtUpAt == nil {
                caughtUpAt = timestamp
                return
            }
            guard timestamp - (caughtUpAt ?? timestamp) >= 0.06 else { return }
            finish()
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            visibleCount = targetCharacters.count
            replaceRenderedText(targetText)
            stop()
            scheduleHeightMeasurement()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isAttached, self.didFinish else { return }
                self.onFinished()
            }
        }

        fileprivate func scheduleHeightMeasurement() {
            guard isAttached, heightMeasurementTask == nil else { return }
            let elapsed = CACurrentMediaTime() - lastHeightMeasurementAt
            let delay = max(0, 0.05 - elapsed)
            let task = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView else { return }
                self.heightMeasurementTask = nil
                let width = textView.bounds.width
                guard self.isAttached, width > 0 else { return }
                let size = textView.sizeThatFits(
                    CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                )
                let height = ceil(size.height)
                if abs(self.measuredHeight.wrappedValue - height) > 0.5 {
                    self.measuredHeight.wrappedValue = height
                }
                self.lastHeightMeasurementAt = CACurrentMediaTime()
            }
            heightMeasurementTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }
}

private final class DisplayLinkTarget: NSObject {
    weak var coordinator: StreamingTextView.Coordinator?

    init(coordinator: StreamingTextView.Coordinator) {
        self.coordinator = coordinator
    }

    @objc func advance(_ link: CADisplayLink) {
        coordinator?.advanceFrame(link)
    }
}
