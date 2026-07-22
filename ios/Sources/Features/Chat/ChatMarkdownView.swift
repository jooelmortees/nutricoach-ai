import Foundation
import SwiftStreamingMarkdown
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatMarkdownView: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var interactions = ChatMarkdownInteractions()

    var body: some View {
        SwiftStreamingMarkdown.MarkdownView(
            text: text,
            config: ChatMarkdownStyle.standard(dynamicTypeSize: dynamicTypeSize),
            listener: interactions
        )
        .id(dynamicTypeSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
        .chatMarkdownExporter(interactions)
    }
}

struct StreamingChatMarkdownView: View {
    let text: String
    let isStreaming: Bool
    let onRevealFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var source: ChatMarkdownSource
    @StateObject private var interactions = ChatMarkdownInteractions()

    init(
        text: String,
        isStreaming: Bool,
        onRevealFinished: @escaping () -> Void
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.onRevealFinished = onRevealFinished
        _source = StateObject(wrappedValue: ChatMarkdownSource(initialText: text))
    }

    var body: some View {
        SwiftStreamingMarkdown.StreamedMarkdownView(
            source: source,
            config: ChatMarkdownStyle.streaming(
                dynamicTypeSize: dynamicTypeSize,
                reduceMotion: reduceMotion
            ),
            listener: interactions
        )
        .id(dynamicTypeSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
        .chatMarkdownExporter(interactions)
        .onAppear {
            source.setRevealImmediately(reduceMotion)
            source.update(text)
            if !isStreaming {
                source.finish(with: text)
            }
            if source.hasFinishedRevealing {
                onRevealFinished()
            }
        }
        .onChange(of: text) { _, newText in
            source.update(newText)
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                source.finish(with: text)
            }
        }
        .onChange(of: source.hasFinishedRevealing) { _, finished in
            if finished {
                onRevealFinished()
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            source.setRevealImmediately(shouldReduceMotion)
        }
    }
}

private final class ChatMarkdownInteractions: ObservableObject, MarkdownListener {
    @Published var isExporting = false
    @Published var exportDocument = ChatMarkdownDocument(content: "")

    func onRender(markdown: RenderableDocument) async {}

    func onTableCopyTap(content: String) async {
        await MainActor.run {
            UIPasteboard.general.string = content
            UIAccessibility.post(notification: .announcement, argument: "Tabla copiada")
        }
    }

    func onTableDownloadTap(content: String) async {
        await MainActor.run {
            exportDocument = ChatMarkdownDocument(content: content)
            isExporting = true
        }
    }

    func onContextMenuAppear(id: String, selectedContent: String) async {}
    func onContextMenuTap(id: String, selectedContent: String) async {}
}

private struct ChatMarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [ChatMarkdownExport.contentType]
    }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let content = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.content = content
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

private enum ChatMarkdownExport {
    static let contentType = UTType(filenameExtension: "md") ?? .plainText
}

private extension View {
    func chatMarkdownExporter(_ interactions: ChatMarkdownInteractions) -> some View {
        fileExporter(
            isPresented: Binding(
                get: { interactions.isExporting },
                set: { interactions.isExporting = $0 }
            ),
            document: interactions.exportDocument,
            contentType: ChatMarkdownExport.contentType,
            defaultFilename: "tabla"
        ) { result in
            if case .failure(let error) = result {
                AppLogger.warning("No se pudo exportar la tabla: \(error.localizedDescription)")
            }
        }
    }
}

private final class ChatMarkdownSource: ObservableObject, StreamedMarkdownSource, @unchecked Sendable {
    private static let revealInterval = DispatchTimeInterval.milliseconds(4)

    private let stateQueue = DispatchQueue(label: "com.nutricoach.chat-markdown-source")
    private var targetText: String
    private var displayedText = ""
    private var pendingScalars: [Unicode.Scalar]
    private var pendingScalarIndex = 0
    private var pendingReplacement: String?
    private var pendingSnapshot: String?
    private var revealImmediately = false
    private var finishRequested = false
    private var isFinished = false
    private var activeSubscriptionID: UUID?
    private var continuation: AsyncStream<String>.Continuation?
    private var revealTimer: DispatchSourceTimer?
    @Published private(set) var hasFinishedRevealing = false

    var text: AsyncStream<String> {
        let subscriptionID = UUID()
        let stream = AsyncStream.makeStream(
            of: String.self,
            // Un único snapshot pendiente aplica backpressure sin saltar caracteres.
            bufferingPolicy: .bufferingOldest(1)
        )
        stream.continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(subscriptionID)
        }

        let shouldFinish = stateQueue.sync {
            stream.continuation.yield(displayedText)
            if !isFinished {
                continuation?.finish()
                activeSubscriptionID = subscriptionID
                continuation = stream.continuation
                startRevealTimerIfNeeded()
            }
            return isFinished
        }

        if shouldFinish {
            stream.continuation.finish()
        }
        return stream.stream
    }

    init(initialText: String) {
        targetText = initialText
        pendingScalars = Array(initialText.unicodeScalars)
    }

    func update(_ newText: String) {
        stateQueue.sync {
            guard !isFinished, !finishRequested else { return }
            enqueue(newText)
            startRevealTimerIfNeeded()
        }
    }

    func setRevealImmediately(_ shouldRevealImmediately: Bool) {
        stateQueue.sync {
            guard revealImmediately != shouldRevealImmediately else { return }
            revealImmediately = shouldRevealImmediately
            if shouldRevealImmediately,
               !displayedText.utf8.elementsEqual(targetText.utf8) {
                pendingScalars.removeAll(keepingCapacity: true)
                pendingScalarIndex = 0
                pendingReplacement = targetText
                pendingSnapshot = nil
                startRevealTimerIfNeeded()
            }
        }
    }

    func finish(with finalText: String) {
        stateQueue.sync {
            guard !isFinished else { return }
            enqueue(finalText)
            finishRequested = true
            finishIfReady()
            startRevealTimerIfNeeded()
        }
    }

    private func removeContinuation(_ id: UUID) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard activeSubscriptionID == id else { return }
            activeSubscriptionID = nil
            continuation = nil
            stopRevealTimer()
        }
    }

    private func enqueue(_ newText: String) {
        guard !newText.utf8.elementsEqual(targetText.utf8) else { return }
        if revealImmediately {
            targetText = newText
            pendingScalars.removeAll(keepingCapacity: true)
            pendingScalarIndex = 0
            pendingReplacement = newText
            pendingSnapshot = nil
            return
        }
        guard newText.utf8.starts(with: targetText.utf8) else {
            targetText = newText
            pendingScalars.removeAll(keepingCapacity: true)
            pendingScalarIndex = 0
            pendingReplacement = newText
            pendingSnapshot = nil
            return
        }

        pendingScalars.append(
            contentsOf: newText.unicodeScalars.dropFirst(targetText.unicodeScalars.count)
        )
        targetText = newText
    }

    private func startRevealTimerIfNeeded() {
        guard revealTimer == nil,
              continuation != nil,
              pendingReplacement != nil || pendingScalarIndex < pendingScalars.count else { return }

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.revealInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.revealNextScalar()
        }
        revealTimer = timer
        timer.resume()
    }

    private func revealNextScalar() {
        if let pendingReplacement {
            guard yieldSnapshot(pendingReplacement) else { return }
            displayedText = pendingReplacement
            self.pendingReplacement = nil
            if pendingScalarIndex == pendingScalars.count {
                stopRevealTimer()
                finishIfReady()
            }
            return
        }

        guard pendingScalarIndex < pendingScalars.count else {
            stopRevealTimer()
            finishIfReady()
            return
        }

        let nextText = pendingSnapshot ?? (displayedText + String(pendingScalars[pendingScalarIndex]))
        pendingSnapshot = nextText
        guard yieldSnapshot(nextText) else { return }
        pendingSnapshot = nil
        displayedText = nextText
        pendingScalarIndex += 1

        if pendingScalarIndex == pendingScalars.count {
            pendingScalars.removeAll(keepingCapacity: true)
            pendingScalarIndex = 0
            stopRevealTimer()
            finishIfReady()
        }
    }

    private func finishIfReady() {
        guard finishRequested,
              pendingReplacement == nil,
              pendingScalarIndex == pendingScalars.count,
              displayedText.utf8.elementsEqual(targetText.utf8) else { return }
        isFinished = true
        continuation?.finish()
        activeSubscriptionID = nil
        continuation = nil
        stopRevealTimer()
        DispatchQueue.main.async { [weak self] in
            self?.hasFinishedRevealing = true
        }
    }

    private func yieldSnapshot(_ snapshot: String) -> Bool {
        guard let continuation else {
            stopRevealTimer()
            return false
        }
        switch continuation.yield(snapshot) {
        case .enqueued:
            return true
        case .dropped:
            return false
        case .terminated:
            activeSubscriptionID = nil
            self.continuation = nil
            stopRevealTimer()
            return false
        @unknown default:
            return false
        }
    }

    private func stopRevealTimer() {
        revealTimer?.setEventHandler {}
        revealTimer?.cancel()
        revealTimer = nil
    }
}

private enum ChatMarkdownStyle {
    private static let cache = ChatMarkdownConfigCache()

    static func standard(dynamicTypeSize: DynamicTypeSize) -> MarkdownRenderConfig {
        cache.value(for: dynamicTypeSize) {
            makeStandard(dynamicTypeSize: dynamicTypeSize)
        }
    }

    static func streaming(
        dynamicTypeSize: DynamicTypeSize,
        reduceMotion: Bool
    ) -> MarkdownRenderConfig {
        standard(dynamicTypeSize: dynamicTypeSize)
            .withShouldAnimateText(value: !reduceMotion)
    }

    private static func makeStandard(dynamicTypeSize: DynamicTypeSize) -> MarkdownRenderConfig {
        let primary = Color(uiColor: .label)
        let secondary = Color(uiColor: .secondaryLabel)
        let subtleBackground = Color(uiColor: .secondarySystemBackground)
        let inlineBackground = Color(uiColor: .tertiarySystemFill)
        let border = Color(uiColor: .separator)
        let accent = Color.accentColor
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory
        )

        let bodyFonts = textFonts(textStyle: .body, size: 17, compatibleWith: traits)
        let tableFonts = textFonts(textStyle: .subheadline, size: 15, compatibleWith: traits)
        let codeFont = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            compatibleWith: traits
        )
        let citationFont = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: UIFont.systemFont(ofSize: 11, weight: .medium),
            compatibleWith: traits
        )

        return MarkdownRenderConfig(
            shouldAnimateText: false,
            blockQuoteStyle: .init(
                textFonts: bodyFonts,
                textColor: secondary
            ),
            headingStyle: .init(
                h1Font: textFonts(
                    textStyle: .title2,
                    size: 24,
                    normalWeight: .semibold,
                    compatibleWith: traits
                ),
                h2Font: textFonts(
                    textStyle: .title2,
                    size: 22,
                    normalWeight: .semibold,
                    compatibleWith: traits
                ),
                h3Font: textFonts(
                    textStyle: .title3,
                    size: 20,
                    normalWeight: .semibold,
                    compatibleWith: traits
                ),
                h4Font: textFonts(
                    textStyle: .headline,
                    size: 17,
                    normalWeight: .semibold,
                    compatibleWith: traits
                ),
                h5Font: textFonts(
                    textStyle: .subheadline,
                    size: 15,
                    normalWeight: .semibold,
                    compatibleWith: traits
                ),
                h6Font: textFonts(
                    textStyle: .subheadline,
                    size: 15,
                    normalWeight: .medium,
                    compatibleWith: traits
                ),
                textColor: primary
            ),
            orderedListStyle: .init(
                textFonts: bodyFonts,
                textColor: primary
            ),
            paragraphStyle: .init(
                textFonts: bodyFonts,
                textColor: primary
            ),
            tableStyle: .init(
                textFonts: tableFonts,
                headerTextColor: primary,
                regularTextColor: primary,
                headerBackgroundColor: subtleBackground,
                borderColor: border,
                actionButtonColor: accent
            ),
            inlineStyle: .init(
                boldTextColor: primary,
                linkTextFont: bodyFonts.normal,
                linkTextColor: Color(uiColor: .link),
                codeTextFont: codeFont,
                codeTextColor: primary,
                codeBackgroundColor: inlineBackground,
                codeUnderlineColor: border
            ),
            textContextMenu: nil,
            citationConfig: .init(
                isEnabled: true,
                coder: .default,
                font: citationFont,
                textColor: primary,
                backgroundColor: inlineBackground
            ),
            codeBlockConfig: .init(
                theme: .xcode,
                backgroundColor: subtleBackground,
                foregroundColor: secondary
            ),
            blockSpacing: 10
        )
    }

    private static func textFonts(
        textStyle: UIFont.TextStyle,
        size: CGFloat,
        normalWeight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection
    ) -> TextFonts {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let normal = metrics.scaledFont(
            for: UIFont.systemFont(ofSize: size, weight: normalWeight),
            compatibleWith: traits
        )
        let bold = metrics.scaledFont(
            for: UIFont.systemFont(ofSize: size, weight: .semibold),
            compatibleWith: traits
        )
        return TextFonts(
            normal: normal,
            italic: italicized(normal),
            bold: bold,
            boldItalic: italicized(bold),
            preferredLetterSpacing: 0,
            preferredLineHeight: nil
        )
    }

    private static func italicized(_ font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

private final class ChatMarkdownConfigCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DynamicTypeSize: MarkdownRenderConfig] = [:]

    func value(
        for dynamicTypeSize: DynamicTypeSize,
        create: () -> MarkdownRenderConfig
    ) -> MarkdownRenderConfig {
        lock.lock()
        if let cached = values[dynamicTypeSize] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let newValue = create()
        lock.lock()
        let value = values[dynamicTypeSize] ?? newValue
        values[dynamicTypeSize] = value
        lock.unlock()
        return value
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
