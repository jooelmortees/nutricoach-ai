// ============================================================
// MessageRow - celda individual del chat
// ============================================================

import SwiftUI

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingBubble(text: thinking)
                }
                TextBubble(text: message.content, role: message.role, isStreaming: message.isStreaming)
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }
}

private struct TextBubble: View {
    let text: String
    let role: ChatMessage.Role
    let isStreaming: Bool

    var body: some View {
        Text(text.isEmpty && isStreaming ? "..." : text)
            .textSelection(.enabled)
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
