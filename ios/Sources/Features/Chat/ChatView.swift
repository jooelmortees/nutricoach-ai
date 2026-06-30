// ============================================================
// ChatView - chat con el agente (streaming thinking + texto)
// ============================================================

import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText: String = ""
    /// Seleccion multiple del PhotosPicker. NO se sube hasta enviar.
    @State private var selectedItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    /// Imagen abierta en fullscreen (tap en thumbnail).
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
                            Label("Nueva conversación", systemImage: "plus.bubble.fill")
                        }
                        Button {
                            // Regenerar la ultima respuesta
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
            .confirmationDialog("¿Limpiar el chat?", isPresented: $showClearConfirm) {
                Button("Limpiar", role: .destructive) {
                    viewModel.clearConversation()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borrarán los mensajes de esta conversación en pantalla. La conversación seguirá existiendo en la base de datos.")
            }
        }
    }

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
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Preview horizontal de imagenes pendientes (estilo Gemini)
            if !viewModel.pendingAttachments.isEmpty {
                PendingAttachmentsStrip(
                    attachments: viewModel.pendingAttachments,
                    onRemove: { id in viewModel.removePendingAttachment(id: id) }
                )
                .padding(.horizontal, 16)
            }
            Divider()
            HStack(spacing: 12) {
                // PhotosPicker multi-select: selectionLimit = nil -> ilimitadas
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
                        // Limpiar la selección del PhotosPicker para poder
                        // volver a seleccionar las mismas imagenes en otro envio
                        selectedItems = []
                    }
                }

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
    }

    private var inputPlaceholder: String {
        viewModel.pendingAttachments.isEmpty
            ? "Pregúntale a tu dietista..."
            : "Escribe tu pregunta..."
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.pendingAttachments.isEmpty
        return (hasText || hasAttachments) && !viewModel.isAgentThinking
    }

    private func send() async {
        // Limpiar inputText, focus y selectedItems ANTES del await para que
        // el UI se sienta inmediato y no parezca que el boton "no hace nada"
        // (que era el bug reportado: el texto se quedaba y habia que cerrar
        // la app si el stream se colgaba sin 'done').
        let text = inputText
        inputText = ""
        inputFocused = false
        await viewModel.send(text: text)
    }

    /// True si el mensaje en `index` es el ULTIMO mensaje del asistente
    /// (no streaming). Solo ese muestra el boton "Regenerar".
    private func isLastAssistant(index: Int) -> Bool {
        let msgs = viewModel.messages
        guard index < msgs.count else { return false }
        guard msgs[index].role == .assistant else { return false }
        guard !msgs[index].isStreaming else { return false }
        // Verificar que no hay otro assistant despues
        for i in (index + 1)..<msgs.count {
            if msgs[i].role == .assistant && !msgs[i].isStreaming {
                return false
            }
        }
        return true
    }
}

/// Wrapper Identifiable para usar .sheet(item:) con un String.
private struct ImageViewerID: Identifiable {
    let url: String
    var id: String { url }
}

/// Strip horizontal de previews de imagenes pendientes (estilo Gemini).
/// Solo muestra las imagenes, sin texto. Cada una con boton X para quitar.
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
                        // Boton X encima de la imagen
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

/// Vista fullscreen para ampliar una imagen del chat (tap en thumbnail).
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
            // Boton cerrar (X) arriba a la derecha
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