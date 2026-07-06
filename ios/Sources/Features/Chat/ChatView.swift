// ============================================================
// ChatView - chat con el agente (streaming thinking + texto + audio)
// ============================================================

import SwiftUI
import PhotosUI
import AVFoundation

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var speechTranscriber = SpeechTranscriber()
    @State private var inputText: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    @State private var fullscreenImageURL: String?
    @State private var showClearConfirm: Bool = false
    @State private var isPinnedToBottom: Bool = true
    @State private var isRecordingAudio: Bool = false
    @State private var pendingAudioURL: URL?
    @State private var isTranscribing: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messagesList
                inputBar
            }
            .navigationTitle("NutriCoach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await viewModel.newConversation() }
                        } label: {
                            Label("Nueva conversacion", systemImage: "plus.bubble.fill")
                        }
                        Button {
                            Task { await viewModel.regenerateLastResponse() }
                        } label: {
                            Label("Regenerar respuesta", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.messages.last(where: { $0.role == .user }) == nil || viewModel.isAgentThinking)
                        Divider()
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("Limpiar chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                await viewModel.loadOrCreateConversation()
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                inputFocused = false
            }
            .sheet(item: Binding(
                get: { fullscreenImageURL.map { ImageViewerID(url: $0) } },
                set: { fullscreenImageURL = $0?.url }
            )) { id in
                FullScreenImageView(url: id.url) {
                    fullscreenImageURL = nil
                }
            }
            .confirmationDialog("Limpiar el chat?", isPresented: $showClearConfirm) {
                Button("Limpiar", role: .destructive) {
                    viewModel.clearConversation()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borraran los mensajes de esta conversacion en pantalla. La conversacion seguira existiendo en la base de datos.")
            }
        }
    }

    // MARK: - Messages list

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let err = viewModel.errorMessage {
                        ErrorBanner(message: err) {
                            viewModel.errorMessage = nil
                        }
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, msg in
                        MessageRow(
                            message: msg,
                            onImageTap: { url in fullscreenImageURL = url },
                            onSaveMeal: { meal in
                                await viewModel.saveMeal(meal)
                            },
                            onRegenerate: isLastAssistant(index: index) ? {
                                Task { await viewModel.regenerateLastResponse() }
                            } : nil
                        )
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // Auto-scroll solo cuando se anade un mensaje nuevo
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            // Durante streaming: solo scroll si el user ya esta abajo
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard isPinnedToBottom, let lastId = viewModel.messages.last?.id else { return }
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 6) {
            // Preview de imagenes pendientes
            if !viewModel.pendingAttachments.isEmpty {
                PendingAttachmentsStrip(
                    attachments: viewModel.pendingAttachments,
                    onRemove: { id in viewModel.removePendingAttachment(id: id) }
                )
                .padding(.horizontal, 16)
            }

            // Preview de audio grabado (antes de transcribir)
            if let audioURL = pendingAudioURL, !isRecordingAudio {
                AudioPreviewBar(
                    url: audioURL,
                    isTranscribing: isTranscribing,
                    onSend: { Task { await sendAudio(url: audioURL) } },
                    onCancel: {
                        pendingAudioURL = nil
                        try? FileManager.default.removeItem(at: audioURL)
                    }
                )
                .padding(.horizontal, 16)
            }

            // Barra de grabacion en vivo (waveform)
            if isRecordingAudio {
                RecordingBar(
                    amplitude: audioRecorder.amplitude,
                    duration: audioRecorder.duration,
                    onStop: { stopAudioRecording() },
                    onCancel: { cancelAudioRecording() }
                )
                .padding(.horizontal, 16)
            }

            Divider()

            HStack(spacing: 10) {
                // Picker de imagenes
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: nil,
                    matching: .images
                ) {
                    Image(systemName: viewModel.pendingAttachments.isEmpty
                          ? "photo.on.rectangle"
                          : "photo.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .onChange(of: selectedItems) { _, newItems in
                    Task {
                        await viewModel.handlePickedImages(newItems)
                        selectedItems = []
                    }
                }
                .disabled(isRecordingAudio || viewModel.isAgentThinking)

                // Boton micro (grabar audio)
                Button {
                    if isRecordingAudio {
                        stopAudioRecording()
                    } else {
                        startAudioRecording()
                    }
                } label: {
                    Image(systemName: isRecordingAudio ? "stop.circle.fill" : "mic.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(isRecordingAudio ? .red : .green)
                }
                .disabled(viewModel.isAgentThinking)

                // Campo de texto
                TextField(
                    inputPlaceholder,
                    text: $inputText,
                    axis: .vertical
                )
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit {
                    Task { await send() }
                }
                .disabled(isRecordingAudio)

                // Boton enviar
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: isRecordingAudio)
        .animation(.easeInOut(duration: 0.2), value: pendingAudioURL != nil)
    }

    private var inputPlaceholder: String {
        if isRecordingAudio { return "Grabando audio..." }
        if viewModel.pendingAttachments.isEmpty { return "Preguntale a tu dietista..." }
        return "Escribe tu pregunta..."
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.pendingAttachments.isEmpty
        let hasAudio = pendingAudioURL != nil
        return (hasText || hasAttachments || hasAudio) && !viewModel.isAgentThinking && !isRecordingAudio && !isTranscribing
    }

    // MARK: - Send

    private func send() async {
        let text = inputText
        inputText = ""
        inputFocused = false
        await viewModel.send(text: text)
    }

    private func sendAudio(url: URL) async {
        isTranscribing = true
        // Transcribir audio a texto
        let transcribed = await speechTranscriber.transcribe(audioURL: url)
        isTranscribing = false

        if let text = transcribed, !text.isEmpty {
            await viewModel.send(text: text)
        } else {
            viewModel.errorMessage = speechTranscriber.errorMessage ?? "No se pudo transcribir el audio"
        }

        // Limpiar
        pendingAudioURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Audio recording

    private func startAudioRecording() {
        audioRecorder.startRecording()
        isRecordingAudio = true
    }

    private func stopAudioRecording() {
        audioRecorder.stopRecording()
        isRecordingAudio = false
        pendingAudioURL = audioRecorder.audioURL
    }

    private func cancelAudioRecording() {
        audioRecorder.cancelRecording()
        isRecordingAudio = false
        pendingAudioURL = nil
    }

    // MARK: - Helpers

    private func isLastAssistant(index: Int) -> Bool {
        let msgs = viewModel.messages
        guard index < msgs.count else { return false }
        guard msgs[index].role == .assistant else { return false }
        guard !msgs[index].isStreaming else { return false }
        for i in (index + 1)..<msgs.count {
            if msgs[i].role == .assistant && !msgs[i].isStreaming {
                return false
            }
        }
        return true
    }
}

// MARK: - Recording bar (waveform en vivo)

struct RecordingBar: View {
    let amplitude: CGFloat
    let duration: TimeInterval
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Waveform animado
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { i in
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 3, height: barHeight(i))
                        .animation(.easeOut(duration: 0.05), value: amplitude)
                }
            }
            .frame(height: 32)

            Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                .font(.caption)
                .foregroundStyle(.red)
                .monospacedDigit()

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // Variar altura de cada barra segun amplitud + offset del indice
        let offset = CGFloat(index) * 0.05
        let base = max(4, amplitude * 32 + offset * 8)
        return min(base, 32)
    }
}

// MARK: - Audio preview bar (antes de enviar)

struct AudioPreviewBar: View {
    let url: URL
    let isTranscribing: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isTranscribing {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Transcribiendo...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Audio listo para enviar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if !isTranscribing {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Helpers

private struct ImageViewerID: Identifiable {
    let url: String
    var id: String { url }
}

struct PendingAttachmentsStrip: View {
    let attachments: [PendingAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: att.preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            onRemove(att.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white, Color.black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FullScreenImageView: View {
    let url: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { onClose() }
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                        Text("No se pudo cargar")
                            .foregroundStyle(.white)
                    }
                @unknown default:
                    EmptyView()
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, Color.black.opacity(0.4))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}