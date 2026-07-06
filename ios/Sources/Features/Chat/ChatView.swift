// ============================================================
// ChatView - chat con el agente (streaming thinking + texto)
// Redisenado desde cero: burbujas profesionales, tools inline,
// animaciones fluidas estilo opencode/scarf/hanlin-ai
// ============================================================

import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    @State private var fullscreenImageURL: String?
    @State private var showClearConfirm: Bool = false

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
                        HStack(spacing: 6) {
                            AssistantAvatar()
                                .padding(.top, 2)
                            ThinkingIndicator()
                                .padding(10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.vertical, 4)
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

    // MARK: - Input bar

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
            Divider()
            HStack(spacing: 10) {
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
                .disabled(viewModel.isAgentThinking)

                TextField(
                    inputPlaceholder,
                    text: $inputText,
                    axis: .vertical
                )
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit {
                    Task { await send() }
                }
                .disabled(viewModel.isAgentThinking)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: viewModel.isAgentThinking
                          ? "stop.circle.fill"
                          : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(viewModel.isAgentThinking ? .red : .green)
                        .symbolEffect(.bounce, value: viewModel.isAgentThinking)
                }
                .disabled(!canSend && !viewModel.isAgentThinking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingAttachments.count)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAgentThinking)
    }

    private var inputPlaceholder: String {
        viewModel.isAgentThinking ? "NutriCoach esta escribiendo..." : "Preguntale a tu dietista..."
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.pendingAttachments.isEmpty
        return (hasText || hasAttachments) && !viewModel.isAgentThinking
    }

    private func send() async {
        let text = inputText
        inputText = ""
        inputFocused = false
        await viewModel.send(text: text)
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