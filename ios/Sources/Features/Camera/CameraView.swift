// ============================================================
// CameraView - captura de fotos para análisis de comidas
// ============================================================

import SwiftUI
import AVFoundation
import PhotosUI

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPicker: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = viewModel.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxHeight: 400)
                    if let analysis = viewModel.analysis {
                        analysisCard(analysis)
                    }
                    if viewModel.isAnalyzing {
                        HStack { ProgressView(); Text("Analizando...") }
                    } else {
                        Button {
                            viewModel.sendToAgent()
                        } label: {
                            Label("Enviar al agente", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.green.gradient, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    placeholder
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Cámara")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await viewModel.loadPickedImage(item) }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 80))
                .foregroundStyle(.green.gradient)
            Text("Toca el botón para fotografiar tu comida")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Elegir de la galería", systemImage: "photo.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.green.gradient, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 40)
    }

    private func analysisCard(_ analysis: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Análisis del agente", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.purple)
            Text(analysis)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var capturedImage: UIImage?
    @Published var analysis: String?
    @Published var isAnalyzing: Bool = false
    @Published var errorMessage: String?

    func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                capturedImage = img
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendToAgent() {
        // TODO fase 2: subir a Supabase Storage y enviar URL al agente
        isAnalyzing = true
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isAnalyzing = false
            analysis = "Análisis pendiente. En fase 2 conectamos con Gemini Vision."
        }
    }
}
