// ============================================================
// ChatView - chat con el agente (streaming thinking + texto)
// ============================================================

import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText: String = ""
    @State private var selectedImage: PhotosPickerItem?
    @FocusState private var inputFocused: Bool

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
                    Button {
                        Task { await viewModel.newConversation() }
                    } label: {
                        Image(systemName: "plus.bubble.fill")
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
                    ForEach(viewModel.messages) { msg in
                        MessageRow(message: msg)
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
            // Preview de la imagen pendiente (estilo Gemini: thumbnail con X para quitar)
            if let pending = viewModel.pendingAttachment {
                PendingAttachmentPreview(
                    image: pending.preview,
                    onCancel: {
                        viewModel.cancelPendingAttachment()
                        selectedImage = nil
                    }
                )
                .padding(.horizontal, 16)
                .transition(.scale.combined(with: .opacity))
            }
            Divider()
            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedImage,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: viewModel.pendingAttachment == nil
                          ? "photo.on.rectangle"
                          : "photo.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .onChange(of: selectedImage) { _, item in
                    Task { await viewModel.handlePickedImage(item) }
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.pendingAttachment)
    }

    private var inputPlaceholder: String {
        viewModel.pendingAttachment != nil
            ? "Pregunta sobre la imagen..."
            : "Pregúntale a tu dietista..."
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = viewModel.pendingAttachment != nil
        return (hasText || hasAttachment) && !viewModel.isAgentThinking
    }

    private func send() async {
        let text = inputText
        await viewModel.send(text: text)
        inputText = ""
        selectedImage = nil
        inputFocused = false
    }
}

/// Preview de imagen pendiente estilo Gemini: thumbnail con botón X.
struct PendingAttachmentPreview: View {
    let image: UIImage
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green.opacity(0.4), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Imagen lista para enviar")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text("Escribe tu pregunta y pulsa enviar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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