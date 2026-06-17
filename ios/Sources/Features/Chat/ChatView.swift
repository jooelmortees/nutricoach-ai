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
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { msg in
                        MessageRow(message: msg)
                            .id(msg.id)
                    }
                    if viewModel.isAgentThinking {
                        ThinkingIndicator()
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedImage, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .onChange(of: selectedImage) { _, item in
                    Task { await viewModel.handlePickedImage(item) }
                }

                TextField("Pregúntale a tu dietista...", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    Task { await viewModel.send(inputText) }
                    inputText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                }
                .disabled(inputText.isEmpty || viewModel.isAgentThinking)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }
}

struct ThinkingIndicator: View {
    @State private var dots: Int = 0
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.purple)
                Text("Pensando" + String(repeating: ".", count: dots))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .onReceive(timer) { _ in
            dots = (dots + 1) % 4
        }
    }
}
