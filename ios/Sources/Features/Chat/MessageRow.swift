// ============================================================
// MessageRow - celda individual del chat
// ============================================================

import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let onImageTap: (String) -> Void

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Thinking oculto en pantalla (plegable tras "Ver razonamiento")
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingBubble(text: thinking)
                }
                // Imagenes adjuntas
                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentsGrid(attachments: attachments, onImageTap: onImageTap)
                }
                TextBubble(text: message.content, role: message.role, isStreaming: message.isStreaming)
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }
}

/// Grid horizontal de thumbnails. Tap para fullscreen.
/// Thumbnails compactos para que quepan mas imagenes por mensaje.
struct AttachmentsGrid: View {
    let attachments: [MessageAttachment]
    let onImageTap: (String) -> Void

    /// Tamano del thumbnail en el grid. Compacto para que quepan mas.
    private let thumbSize: CGFloat = 70
    private let cornerRadius: CGFloat = 8

    var body: some View {
        let images = attachments.filter { $0.type == "image" }
        if images.isEmpty {
            EmptyView()
        } else if images.count == 1 {
            // Una sola imagen: un poco mas grande para verla bien
            singleImage(images[0])
        } else {
            multipleImages(images)
        }
    }

    @ViewBuilder
    private func singleImage(_ att: MessageAttachment) -> some View {
        AsyncImage(url: URL(string: att.url)) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .overlay(ProgressView())
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .onTapGesture { onImageTap(att.url) }
            case .failure:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: thumbSize * 1.8, height: thumbSize * 1.8)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            @unknown default:
                EmptyView()
            }
        }
    }

    private func multipleImages(_ images: [MessageAttachment]) -> some View {
        // Grid horizontal scrollable con thumbnails pequenos.
        // En lugar de grid 2x2 (que ocupa mucho), uso una fila horizontal
        // que cabe bien en pantalla y permite mas imagenes.
        let cols = [
            GridItem(.fixed(thumbSize), spacing: 4),
            GridItem(.fixed(thumbSize), spacing: 4),
            GridItem(.fixed(thumbSize), spacing: 4),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(thumbSize))], spacing: 4) {
                ForEach(images, id: \.url) { att in
                    AsyncImage(url: URL(string: att.url)) { phase in
                        switch phase {
                        case .empty:
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(width: thumbSize, height: thumbSize)
                                .overlay(ProgressView().scaleEffect(0.7))
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: thumbSize, height: thumbSize)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                .onTapGesture { onImageTap(att.url) }
                        case .failure:
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color(.tertiarySystemBackground))
                                .frame(width: thumbSize, height: thumbSize)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .frame(height: thumbSize)
    }
}

private struct TextBubble: View {
    let text: String
    let role: ChatMessage.Role
    let isStreaming: Bool

    @State private var dots: Int = 1

    private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if text.isEmpty && isStreaming {
                // 3 circulos pequenos que parpadean (estilo Gemini)
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                            .opacity(i < dots ? 1.0 : 0.3)
                    }
                }
                .frame(width: 36, height: 22, alignment: .center)
                .onReceive(timer) { _ in
                    dots = (dots % 3) + 1
                }
            } else {
                Text(text)
                    .textSelection(.enabled)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(fg)
    }

    private var bg: Color {
        role == .user ? .green : Color(.secondarySystemBackground)
    }

    private var fg: Color {
        role == .user ? .white : .primary
    }
}

private struct ThinkingBubble: View {
    let text: String
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                    Text(isExpanded ? "Ocultar razonamiento" : "Ver razonamiento")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(.purple)
            }
            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.bottom, 2)
    }
}