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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var audioPlayback = AudioPlaybackController()
    @StateObject private var photoLibrary = PhotoLibraryService.shared
    @State private var inputText: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    @State private var fullscreenImageURL: String?
    @State private var showClearConfirm: Bool = false
    @State private var webSearchEnabled: Bool = false
    @State private var showPlusMenu: Bool = false
    @State private var showCamera: Bool = false
    @State private var showFullGallery: Bool = false
    @State private var isPinnedToBottom = true
    @State private var shouldFollowResponse = true
    @State private var isUserScrolling = false
    @State private var bottomDistance = CGFloat.greatestFiniteMagnitude
    @State private var scrollToBottomRequest = 0
    @State private var recordingTask: Task<Void, Never>?

    private let bottomAnchorId = "chat-bottom-anchor"

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    messagesList
                    inputBar
                }
                .background(Color(.systemBackground))

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
                            Task { await startNewConversation() }
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
                requestScrollToBottom()
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
                maxSelectionCount: 8,
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
                    clearConversation()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borraran los mensajes de esta conversacion en pantalla. La conversacion seguira existiendo en la base de datos.")
            }
            .onDisappear {
                recordingTask?.cancel()
                recordingTask = nil
                if audioRecorder.isRecording || audioRecorder.isRequestingPermission {
                    audioRecorder.cancelRecording()
                }
                audioPlayback.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active && (audioRecorder.isRecording || audioRecorder.isRequestingPermission) {
                    cancelAudioRecording()
                }
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if viewModel.hasMoreHistory || viewModel.isLoadingOlderMessages {
                                Button {
                                    loadOlderMessages(using: proxy)
                                } label: {
                                    if viewModel.isLoadingOlderMessages {
                                        ProgressView()
                                    } else {
                                        Label("Mensajes anteriores", systemImage: "arrow.up")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                                .disabled(viewModel.isLoadingOlderMessages)
                            }

                            if let err = viewModel.errorMessage {
                                ErrorBanner(message: err) {
                                    viewModel.errorMessage = nil
                                }
                                .padding(.bottom, 8)
                            }
                            ForEach(viewModel.messages) { msg in
                                MessageRow(
                                    message: msg,
                                    audioPlayback: audioPlayback,
                                    onImageTap: { url in fullscreenImageURL = url },
                                    onSaveMeal: { meal in
                                        await viewModel.saveMeal(meal)
                                    }
                                )
                                .id(msg.id)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorId)
                                .background {
                                    GeometryReader { marker in
                                        Color.clear.preference(
                                            key: ChatBottomPositionPreferenceKey.self,
                                            value: marker.frame(in: .named("chat-scroll")).maxY
                                        )
                                    }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { _ in
                                isUserScrolling = true
                                shouldFollowResponse = false
                            }
                            .onEnded { _ in
                                isUserScrolling = false
                                updatePinnedState()
                                if !viewModel.isAgentThinking && isPinnedToBottom {
                                    shouldFollowResponse = true
                                }
                            }
                    )

                    if !shouldFollowResponse || !isPinnedToBottom {
                        Button {
                            shouldFollowResponse = true
                            isPinnedToBottom = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ir al final del chat")
                        .padding(12)
                    }
                }
                .onPreferenceChange(ChatBottomPositionPreferenceKey.self) { bottomY in
                    bottomDistance = bottomY - viewport.size.height
                    updatePinnedState()
                }
                .onChange(of: scrollToBottomRequest) { _, _ in
                    shouldFollowResponse = true
                    isPinnedToBottom = true
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.messages.last?.id) { _, _ in
                    guard shouldFollowResponse else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                    }
                }
                .task(id: viewModel.isAgentThinking) {
                    while viewModel.isAgentThinking && !Task.isCancelled {
                        if shouldFollowResponse && !isUserScrolling {
                            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                        }
                        try? await Task.sleep(nanoseconds: 90_000_000)
                    }
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

            if let recording = audioRecorder.recordedAudio {
                AudioAttachmentCard(
                    id: recording.id,
                    title: "Grabación de voz",
                    duration: recording.duration,
                    sizeBytes: recording.sizeBytes,
                    localURL: recording.fileURL,
                    onRemove: {
                        audioPlayback.stop()
                        audioRecorder.discardRecordedAudio()
                    },
                    playback: audioPlayback
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let audioError = audioRecorder.errorMessage {
                ErrorBanner(message: audioError) {
                    audioRecorder.errorMessage = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let playbackError = audioPlayback.errorMessage {
                ErrorBanner(message: playbackError) {
                    audioPlayback.errorMessage = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Barra de entrada estilo Claude
            ChatInputBar(
                text: $inputText,
                placeholder: inputPlaceholder,
                isAgentThinking: viewModel.isAgentThinking || viewModel.isSending || audioRecorder.isRequestingPermission,
                isRecordingAudio: audioRecorder.isRecording,
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
                    if audioRecorder.isRecording {
                        Task { await stopAudioRecording() }
                    } else {
                        recordingTask?.cancel()
                        recordingTask = Task { await startAudioRecording() }
                    }
                },
                onCancelRecording: {
                    cancelAudioRecording()
                },
                onSend: {
                    Task { await send() }
                },
                isFocused: $inputFocused
            )
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: audioRecorder.isRecording)
        .animation(.easeInOut(duration: 0.2), value: audioRecorder.recordedAudio != nil)
    }

    private var inputPlaceholder: String {
        "Pregunta a NutriCoach"
    }

    private func send() async {
        let text = inputText
        let useWebSearch = webSearchEnabled
        let sent = await viewModel.send(
            text: text,
            recordedAudio: audioRecorder.recordedAudio,
            webSearch: useWebSearch
        )
        if sent {
            inputText = ""
            inputFocused = false
            audioPlayback.stop()
            audioRecorder.discardRecordedAudio()
            requestScrollToBottom()
        }
    }

    // MARK: - Imagen desde cámara

    private func addCameraImage(_ image: UIImage) {
        guard viewModel.pendingAttachments.count < 8 else {
            viewModel.errorMessage = "Puedes adjuntar hasta ocho archivos."
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let compressed = compressImageData(data, maxBytes: 2 * 1024 * 1024) ?? data
        guard let preview = UIImage(data: compressed) else { return }
        viewModel.pendingAttachments.append(
            PendingAttachment(imageData: compressed, preview: preview)
        )
    }

    // MARK: - Imagen desde galería reciente (PHAsset)

    private func addRecentPhoto(_ asset: PHAsset) async {
        guard viewModel.pendingAttachments.count < 8 else {
            viewModel.errorMessage = "Puedes adjuntar hasta ocho archivos."
            return
        }
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

    private func startAudioRecording() async {
        audioPlayback.stop()
        await audioRecorder.startRecording()
    }

    private func stopAudioRecording() async {
        await audioRecorder.stopRecording()
        recordingTask = nil
    }

    private func cancelAudioRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        audioRecorder.cancelRecording()
    }

    private func startNewConversation() async {
        cancelAudioDraft()
        await viewModel.newConversation()
        requestScrollToBottom()
    }

    private func clearConversation() {
        cancelAudioDraft()
        viewModel.clearConversation()
        requestScrollToBottom()
    }

    private func cancelAudioDraft() {
        recordingTask?.cancel()
        recordingTask = nil
        audioPlayback.stop()
        audioRecorder.cancelRecording()
        audioRecorder.discardRecordedAudio()
    }

    private func requestScrollToBottom() {
        scrollToBottomRequest += 1
    }

    private func updatePinnedState() {
        isPinnedToBottom = bottomDistance <= 72
    }

    private func loadOlderMessages(using proxy: ScrollViewProxy) {
        guard let anchorId = viewModel.messages.first?.id else { return }
        Task {
            await viewModel.loadOlderMessages()
            await Task.yield()
            proxy.scrollTo(anchorId, anchor: .top)
        }
    }
}

private struct ChatBottomPositionPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
