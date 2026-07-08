// ============================================================
// ChatView - chat con el agente (streaming thinking + texto)
// Redisenado desde cero: burbujas profesionales, tools inline,
// animaciones fluidas estilo opencode/scarf/hanlin-ai
// ============================================================

import SwiftUI
import PhotosUI
import AVFoundation
import Photos

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var photoLibrary = PhotoLibraryService.shared
    @State private var inputText: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    @State private var fullscreenImageURL: String?
    @State private var showClearConfirm: Bool = false
    @State private var webSearchEnabled: Bool = false
    @State private var isRecordingAudio: Bool = false
    @State private var showPlusMenu: Bool = false
    @State private var showCamera: Bool = false
    @State private var showFullGallery: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    messagesList
                    inputBar
                }

                // Overlay del bottom sheet del botón "+"
                if showPlusMenu {
                    plusMenuOverlay
                }
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
            .sheet(isPresented: $showCamera) {
                CameraPicker(
                    onImage: { image in
                        addCameraImage(image)
                    },
                    onCancel: {}
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showFullGallery,
                selection: $selectedItems,
                maxSelectionCount: nil,
                matching: .images
            )
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await viewModel.handlePickedImages(newItems)
                    selectedItems = []
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

    // MARK: - Overlay del bottom sheet del botón "+"

    private var plusMenuOverlay: some View {
        ZStack {
            // Fondo semitransparente que captura taps para cerrar
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showPlusMenu = false
                    }
                }
            VStack {
                Spacer()
                PlusMenuSheet(
                    webSearchEnabled: $webSearchEnabled,
                    photoLibrary: photoLibrary,
                    onOpenCamera: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showPlusMenu = false
                        }
                        showCamera = true
                    },
                    onOpenFullGallery: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showPlusMenu = false
                        }
                        showFullGallery = true
                    },
                    onPickRecent: { asset in
                        withAnimation(.easeOut(duration: 0.25)) {
                            showPlusMenu = false
                        }
                        Task { await addRecentPhoto(asset) }
                    },
                    onClose: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showPlusMenu = false
                        }
                    }
                )
                .padding(.bottom, 0)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .transition(.opacity)
        .zIndex(10)
    }

    // MARK: - Messages list

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let err = viewModel.errorMessage {
                        ErrorBanner(message: err) {
                            viewModel.errorMessage = nil
                        }
                        .padding(.bottom, 8)
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, msg in
                        MessageRow(
                            message: msg,
                            isLastAssistant: isLastAssistant(index: index),
                            onImageTap: { url in fullscreenImageURL = url },
                            onSaveMeal: { meal in
                                await viewModel.saveMeal(meal)
                            },
                            onRegenerate: isLastAssistant(index: index) ? {
                                Task { await viewModel.regenerateLastResponse() }
                            } : nil
                        )
                        .id(msg.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                    // Indicador de thinking al final
                    if viewModel.isAgentThinking && (viewModel.messages.last?.content.isEmpty ?? true) {
                        ThinkingIndicator()
                            .padding(10)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollTargetLayout()
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input bar (tema carbón estilo Claude)

    private var inputBar: some View {
        VStack(spacing: 0) {
            if !viewModel.pendingAttachments.isEmpty {
                PendingAttachmentsStrip(
                    attachments: viewModel.pendingAttachments,
                    onRemove: { id in viewModel.removePendingAttachment(id: id) }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Barra de entrada estilo Claude
            ChatInputBar(
                text: $inputText,
                placeholder: inputPlaceholder,
                isAgentThinking: viewModel.isAgentThinking,
                isRecordingAudio: isRecordingAudio,
                hasReadyAudio: audioRecorder.audioData != nil,
                hasAttachments: !viewModel.pendingAttachments.isEmpty,
                recorder: audioRecorder,
                onPlusTap: {
                    inputFocused = false
                    Task { await photoLibrary.requestAccessAndLoadRecent(limit: 12) }
                    withAnimation(.easeOut(duration: 0.25)) {
                        showPlusMenu = true
                    }
                },
                onMicTap: {
                    if hasReadyAudio {
                        // Descartar audio anterior y grabar uno nuevo
                        audioRecorder.audioData = nil
                        startAudioRecording()
                    } else if isRecordingAudio {
                        Task { await stopAudioRecording() }
                    } else {
                        startAudioRecording()
                    }
                },
                onCancelRecording: {
                    cancelAudioRecording()
                },
                onSend: {
                    Task {
                        if isRecordingAudio {
                            await stopAudioRecording()
                        }
                        await send()
                    }
                },
                isFocused: $inputFocused
            )
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.10))
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAgentThinking)
        .animation(.easeInOut(duration: 0.2), value: isRecordingAudio)
        .animation(.easeInOut(duration: 0.2), value: audioRecorder.audioData != nil)
        // Sincronizar isRecordingAudio con el estado real del recorder.
        // El recorder puede pararse solo al llegar al límite de 3 min;
        // en ese caso isRecordingAudio (State local) debe refrescarse.
        .onChange(of: audioRecorder.isRecording) { _, newValue in
            if !newValue && isRecordingAudio {
                isRecordingAudio = false
            }
        }
    }

    private var hasReadyAudio: Bool {
        audioRecorder.audioData != nil
    }

    private var inputPlaceholder: String {
        "Chatear con NutriCoach"
    }

    private func send() async {
        let text = inputText
        inputText = ""
        inputFocused = false
        let audioData = audioRecorder.audioData
        let useWebSearch = webSearchEnabled
        await viewModel.send(text: text, audioData: audioData, webSearch: useWebSearch)
        audioRecorder.audioData = nil
    }

    // MARK: - Imagen desde cámara

    private func addCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let compressed = compressImageData(data, maxBytes: 2 * 1024 * 1024) ?? data
        guard let preview = UIImage(data: compressed) else { return }
        viewModel.pendingAttachments.append(
            PendingAttachment(imageData: compressed, preview: preview)
        )
    }

    // MARK: - Imagen desde galería reciente (PHAsset)

    private func addRecentPhoto(_ asset: PHAsset) async {
        guard let data = await photoLibrary.fetchFullImageData(for: asset) else { return }
        let compressed = compressImageData(data, maxBytes: 2 * 1024 * 1024) ?? data
        guard let preview = UIImage(data: compressed) else { return }
        viewModel.pendingAttachments.append(
            PendingAttachment(imageData: compressed, preview: preview)
        )
    }

    private func compressImageData(_ data: Data, maxBytes: Int) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        var quality: CGFloat = 0.8
        var result = data
        while result.count > maxBytes && quality > 0.1 {
            if let jpeg = image.jpegData(compressionQuality: quality) {
                result = jpeg
            }
            quality -= 0.1
        }
        return result
    }

    // MARK: - Audio recording

    private func startAudioRecording() {
        audioRecorder.startRecording()
        isRecordingAudio = true
    }

    private func stopAudioRecording() async {
        await audioRecorder.stopRecording()
        isRecordingAudio = false
    }

    private func cancelAudioRecording() {
        audioRecorder.cancelRecording()
        isRecordingAudio = false
    }

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

// MARK: - Thinking indicator (onda suave estilo waveform)

struct ThinkingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 4, height: barHeight(for: i))
                    .animation(
                        .smooth(duration: 0.8)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: phase
                    )
            }
        }
        .onAppear {
            phase = 1
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [8, 14, 20, 14, 8]
        return heights[index]
    }
}

// MARK: - Wrapper Identifiable para .sheet(item:) con un String.

private struct ImageViewerID: Identifiable {
    let url: String
    var id: String { url }
}

// MARK: - Strip de previews de imagenes pendientes

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
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            onRemove(att.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
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

// MARK: - Error banner

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

// MARK: - Fullscreen image viewer

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